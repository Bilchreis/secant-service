defmodule SecantService.ReadingAggregatesTest do
  @moduledoc """
  The continuous aggregates over `readings`, checked against the scenarios
  of the `reading-aggregates` spec. They refresh views, so they run outside
  the sandbox (see `SecantService.AggregateHelpers`).
  """
  use ExUnit.Case, async: false

  import SecantService.AggregateHelpers

  setup_all :setup_aggregates

  @minute ~U[2026-01-05 10:00:00.000000Z]

  # a time `s` seconds into the test's minute bucket
  defp at(s), do: DateTime.add(@minute, s * 1_000_000, :microsecond)
  defp us(%DateTime{} = t), do: DateTime.to_unix(t, :microsecond) * 1.0

  @double %{"type" => "double"}
  @int %{"type" => "int"}
  @enum %{"type" => "enum", "members" => %{"off" => 0, "on" => 1, "error" => 2}}
  defp array(member),
    do: %{"type" => "array", "members" => member, "minlen" => 0, "maxlen" => 100}

  # The number rows of a parameter, keyed by idx, with the keys decoded.
  defp numbers(parameter, view \\ "reading_numbers_1m") do
    refresh!(view)

    for row <- rows(view, parameter), into: %{} do
      [min, min_at, _] = row["lo"]
      [max, neg_max_at, _] = row["hi"]
      [first_at, _, first] = row["first_key"]
      [last_at, _, last] = row["last_key"]

      {row["idx"],
       %{
         min: min,
         min_at: min_at,
         max: max,
         max_at: -neg_max_at,
         sum: row["sum"],
         count: row["count"],
         first: first,
         first_at: first_at,
         last: last,
         last_at: last_at
       }}
    end
  end

  describe "reading_numbers_1m" do
    test "a double bucket has min, max, mean, first and last with their times" do
      unboxed(fn ->
        p = parameter!(@double)
        insert!(p, [{1.0, at(1)}, {4.0, at(2)}, {2.5, at(3)}])

        assert %{1 => n} = numbers(p)
        assert {n.min, n.min_at, n.max, n.max_at} == {1.0, us(at(1)), 4.0, us(at(2))}
        assert_in_delta n.sum / n.count, 2.5, 1.0e-12
        assert n.count == 3
        assert {n.first, n.first_at, n.last, n.last_at} == {1.0, us(at(1)), 2.5, us(at(3))}
      end)
    end

    test "equal extremes read as the earliest reading" do
      unboxed(fn ->
        p = parameter!(@double)
        insert!(p, [{1.0, at(1)}, {9.0, at(2)}, {1.0, at(3)}, {9.0, at(4)}])

        assert %{1 => %{min_at: min_at, max_at: max_at}} = numbers(p)
        assert {min_at, max_at} == {us(at(1)), us(at(2))}
      end)
    end

    test "readings with the same timestamp are ordered by id" do
      unboxed(fn ->
        p = parameter!(@double)
        insert!(p, [{5.0, at(1)}])
        insert!(p, [{7.0, at(1)}])

        assert %{1 => n} = numbers(p)
        assert {n.first, n.last} == {5.0, 7.0}
      end)
    end

    test "a value too large to sum is left out, and the refresh succeeds" do
      unboxed(fn ->
        p = parameter!(@double)
        insert!(p, [{1.0, at(1)}, {1.0e308, at(2)}, {3.0, at(3)}])

        assert %{1 => n} = numbers(p)
        assert {n.min, n.max, n.count} == {1.0, 3.0, 2}
      end)
    end

    test "integers beyond float precision are compared as float8" do
      unboxed(fn ->
        p = parameter!(@int)
        big = Integer.pow(2, 53)
        insert!(p, [{big, at(1)}, {big + 1, at(2)}])

        assert %{1 => n} = numbers(p)
        assert {n.min, n.max, n.count} == {big * 1.0, big * 1.0, 2}
      end)
    end

    test "a scaled parameter is aggregated unscaled" do
      unboxed(fn ->
        p = parameter!(%{"type" => "scaled", "scale" => 0.1})
        insert!(p, [{10, at(1)}, {30, at(2)}])

        assert %{1 => n} = numbers(p)
        assert {n.min, n.max, n.sum / n.count} == {10.0, 30.0, 20.0}
      end)
    end

    test "each array element is aggregated on its own, and the length is element 0" do
      unboxed(fn ->
        p = parameter!(array(@double))
        insert!(p, [{[1.0, 5.0, 9.0], at(1)}, {[3.0, 2.0, 9.0], at(2)}])

        assert %{0 => len, 1 => e1, 2 => e2, 3 => e3} = numbers(p)
        assert {e1.min, e1.max} == {1.0, 3.0}
        assert {e2.min, e2.max} == {2.0, 5.0}
        assert {e3.min, e3.max} == {9.0, 9.0}
        assert {len.min, len.max, len.count} == {3.0, 3.0, 2}
      end)
    end

    test "readings of different length count per element" do
      unboxed(fn ->
        p = parameter!(array(@double))
        insert!(p, [{[1.0, 2.0], at(1)}, {[1.0, 2.0, 3.0], at(2)}])

        assert %{1 => e1, 2 => e2, 3 => e3} = numbers(p)
        assert {e1.count, e2.count, e3.count} == {2, 2, 1}
      end)
    end

    test "a ragged array that shrinks shows it in element 0" do
      unboxed(fn ->
        p = parameter!(array(@double))
        insert!(p, [{[1.0, 2.0, 3.0], at(1)}, {[4.0, 5.0], at(2)}])

        assert %{0 => len, 3 => e3} = numbers(p)
        assert {len.min, len.max, len.count} == {2.0, 3.0, 2}

        assert {len.first, len.first_at, len.last, len.last_at} ==
                 {3.0, us(at(1)), 2.0, us(at(2))}

        assert {e3.last, e3.last_at} == {3.0, us(at(1))}
      end)
    end

    test "an enum array's length is a number, its elements are not" do
      unboxed(fn ->
        p = parameter!(array(@enum))
        insert!(p, [{[0, 1], at(1)}, {[1], at(2)}])

        assert %{0 => len} = numbers = numbers(p)
        assert map_size(numbers) == 1
        assert {len.min, len.max} == {1.0, 2.0}
      end)
    end

    test "a fixed-length array stores a constant length" do
      unboxed(fn ->
        p = parameter!(array(@double))
        insert!(p, for(s <- 1..3, do: {List.duplicate(s * 1.0, 50), at(s)}))

        numbers = numbers(p)
        assert map_size(numbers) == 51
        assert %{min: 50.0, max: 50.0, count: 3} = numbers[0]
      end)
    end

    test "an empty array counts in element 0 only" do
      unboxed(fn ->
        p = parameter!(array(@double))
        insert!(p, [{[], at(1)}])

        assert %{0 => %{min: +0.0, count: 1}} = numbers = numbers(p)
        assert map_size(numbers) == 1
      end)
    end

    test "an array reading that did not fit its type is in no aggregate" do
      unboxed(fn ->
        p = parameter!(array(@int))
        insert!(p, [{[1, 2.5], at(1)}])

        assert numbers(p) == %{}
      end)
    end

    test "NaN is left out" do
      unboxed(fn ->
        p = parameter!(@double)
        insert!(p, [{1.0, at(1)}, {3.0, at(3)}])
        insert_sql!(p, "value_float", "'NaN'::float8", at(2))

        assert %{1 => n} = numbers(p)
        assert {n.min, n.max, n.sum, n.count} == {1.0, 3.0, 4.0, 2}
      end)
    end

    test "a value that did not fit its type is left out" do
      unboxed(fn ->
        p = parameter!(@int)
        insert!(p, [{2.5, at(1)}, {4, at(2)}])

        assert %{1 => %{min: 4.0, count: 1}} = numbers(p)
      end)
    end

    test "an enum is not a number" do
      unboxed(fn ->
        p = parameter!(@enum)
        insert!(p, [{0, at(1)}, {2, at(2)}])

        assert numbers(p) == %{}
      end)
    end
  end

  # The state rows of a parameter, keyed by {idx, state}.
  defp states(parameter, view \\ "reading_states_1m") do
    refresh!(view)

    for row <- rows(view, parameter), into: %{} do
      {{row["idx"], row["state"]},
       %{first_at: row["first_at"], last_at: row["last_at"], count: row["count"]}}
    end
  end

  # Member rows, keyed by {member, idx} for numbers and {member, idx, state}
  # for states.
  defp member_numbers(parameter, view \\ "reading_member_numbers_1m") do
    refresh!(view)

    for row <- rows(view, parameter), into: %{} do
      [min, _, _] = row["lo"]
      [max, _, _] = row["hi"]
      {{row["member"], row["idx"]}, %{min: min, max: max, count: row["count"]}}
    end
  end

  defp member_states(parameter, view \\ "reading_member_states_1m") do
    refresh!(view)

    for row <- rows(view, parameter), into: %{} do
      {{row["member"], row["idx"], row["state"]}, %{count: row["count"]}}
    end
  end

  defp naive(%DateTime{} = t), do: DateTime.to_naive(t)

  describe "reading_states_1m" do
    test "an enum that changes state has one entry per state" do
      unboxed(fn ->
        p = parameter!(@enum)
        insert!(p, [{0, at(1)}, {2, at(2)}, {0, at(3)}])

        assert %{{1, 0} => off, {1, 2} => error} = states = states(p)
        assert map_size(states) == 2
        assert off == %{first_at: naive(at(1)), last_at: naive(at(3)), count: 2}
        assert error.count == 1
      end)
    end

    test "bools read as 0 and 1" do
      unboxed(fn ->
        p = parameter!(%{"type" => "bool"})
        insert!(p, [{true, at(1)}, {false, at(2)}, {true, at(3)}])

        assert %{{1, 0} => %{count: 1}, {1, 1} => %{count: 2}} = states(p)
      end)
    end

    test "enum and bool arrays have states per element" do
      unboxed(fn ->
        enums = parameter!(array(@enum))
        bools = parameter!(array(%{"type" => "bool"}))
        insert!(enums, [{[0, 1], at(1)}, {[1], at(2)}])
        insert!(bools, [{[true, false], at(1)}])

        assert states(enums) |> Map.keys() |> Enum.sort() == [{1, 0}, {1, 1}, {2, 1}]
        assert states(bools) |> Map.keys() |> Enum.sort() == [{1, 1}, {2, 0}]
      end)
    end

    test "an int is not a state" do
      unboxed(fn ->
        p = parameter!(@int)
        insert!(p, [{1, at(1)}, {2, at(2)}])

        assert states(p) == %{}
      end)
    end

    test "an enum reading that did not fit its type gives no state, not even an empty one" do
      unboxed(fn ->
        p = parameter!(@enum)
        insert!(p, [{"broken", at(1)}, {1, at(2)}])

        assert states(p) |> Map.keys() == [{1, 1}]
      end)
    end
  end

  @struct %{
    "type" => "struct",
    "members" => %{
      "temperature" => @double,
      "count" => @int,
      "mode" => @enum,
      "spectrum" => %{"type" => "array", "members" => @double},
      "limits" => %{"type" => "struct", "members" => %{"lo" => @double}}
    }
  }

  @hour ~U[2026-01-05 10:00:00.000000Z]
  defp at_minute(m, s \\ 0), do: DateTime.add(@hour, m * 60 + s, :second)

  # The 1-minute rows of a view rolled up to hours in Elixir, as decision 5
  # of the design does it in SQL: min/max of the keys, sums of sum and count.
  defp hourly_from_minutes(rows, keys) do
    rows
    |> Enum.group_by(fn row ->
      [row["parameter_id"], %{row["bucket"] | minute: 0}] ++ Enum.map(keys, &row[&1])
    end)
    |> Map.new(fn {key, rows} -> {key, rollup(rows)} end)
  end

  defp rollup([%{"lo" => _} | _] = rows) do
    %{
      "lo" => rows |> Enum.map(& &1["lo"]) |> Enum.min(),
      "hi" => rows |> Enum.map(& &1["hi"]) |> Enum.max(),
      "sum" => rows |> Enum.map(& &1["sum"]) |> Enum.sum(),
      "count" => rows |> Enum.map(& &1["count"]) |> Enum.sum(),
      "first_key" => rows |> Enum.map(& &1["first_key"]) |> Enum.min(),
      "last_key" => rows |> Enum.map(& &1["last_key"]) |> Enum.max()
    }
  end

  defp rollup(rows) do
    %{
      "first_at" => rows |> Enum.map(& &1["first_at"]) |> Enum.min(NaiveDateTime),
      "last_at" => rows |> Enum.map(& &1["last_at"]) |> Enum.max(NaiveDateTime),
      "count" => rows |> Enum.map(& &1["count"]) |> Enum.sum()
    }
  end

  defp hourly(rows, keys) do
    Map.new(rows, fn row ->
      {[row["parameter_id"], row["bucket"]] ++ Enum.map(keys, &row[&1]),
       Map.drop(row, ["parameter_id", "bucket" | keys])}
    end)
  end

  # sums of float sums only match within rounding
  defp assert_same_rollup(expected, actual) do
    assert Map.keys(expected) |> Enum.sort() == Map.keys(actual) |> Enum.sort()

    for {key, want} <- expected do
      got = actual[key]
      assert Map.delete(got, "sum") == Map.delete(want, "sum")
      if want["sum"], do: assert_in_delta(got["sum"], want["sum"], 1.0e-9)
    end
  end

  describe "1-hour tier" do
    test "1-hour buckets equal the same hours rolled up from the 1-minute tier" do
      unboxed(fn ->
        double = parameter!(@double)
        enum = parameter!(@enum)
        struct = parameter!(@struct)

        insert!(double, for(m <- 0..119, do: {:math.sin(m / 7) * 10, at_minute(m, 7)}))
        insert!(enum, for(m <- 0..119, do: {rem(m, 3), at_minute(m, 11)}))

        insert!(
          struct,
          for(m <- 0..119, do: {%{"temperature" => m / 3, "mode" => rem(m, 2)}, at_minute(m, 3)})
        )

        for kind <-
              ~w(reading_numbers reading_states reading_member_numbers reading_member_states) do
          refresh!("#{kind}_1m")
          refresh!("#{kind}_1h")
        end

        cases = [
          {double, "reading_numbers", ["idx"]},
          {enum, "reading_states", ["idx", "state"]},
          {struct, "reading_member_numbers", ["member", "idx"]},
          {struct, "reading_member_states", ["member", "idx", "state"]}
        ]

        for {p, kind, keys} <- cases do
          minutes = rows("#{kind}_1m", p)
          hours = rows("#{kind}_1h", p)
          assert length(hours) > 1
          assert_same_rollup(hourly_from_minutes(minutes, keys), hourly(hours, keys))
        end
      end)
    end

    test "every view has a refresh policy, oldest first, and each 1-minute view a columnstore policy" do
      unboxed(fn ->
        %{rows: rows} =
          SecantService.Repo.query!("""
          SELECT hypertable_name, proc_name, config ->> 'refresh_newest_first'
          FROM timescaledb_information.jobs
          WHERE hypertable_name LIKE 'reading\\_%'
          ORDER BY 1, 2
          """)

        views = SecantService.SecNodes.Reading.AggregateViews.views()
        refresh = for [v, "policy_refresh_continuous_aggregate", newest] <- rows, do: {v, newest}
        columnstore = for [v, "policy_compression", _] <- rows, do: v

        assert length(rows) == 12
        assert Enum.sort(refresh) == views |> Enum.sort() |> Enum.map(&{&1, "false"})

        assert Enum.sort(columnstore) ==
                 views |> Enum.filter(&String.ends_with?(&1, "_1m")) |> Enum.sort()
      end)
    end

    test "an hour refreshed while its minutes were incomplete is corrected by the next refresh" do
      unboxed(fn ->
        p = parameter!(@double)
        insert!(p, [{1.0, at_minute(5)}, {2.0, at_minute(40)}])

        refresh!("reading_numbers_1m", at_minute(0), at_minute(30))
        refresh!("reading_numbers_1h")
        refresh!("reading_numbers_1m")

        assert [%{"count" => 1}] = rows("reading_numbers_1h", p)

        refresh!("reading_numbers_1h")
        assert [%{"count" => 2}] = rows("reading_numbers_1h", p)
      end)
    end
  end

  describe "kept up to date" do
    test "a deleted parameter's buckets are gone from every tier after a refresh" do
      unboxed(fn ->
        double = parameter!(@double)
        enum = parameter!(@enum)
        struct = parameter!(@struct)
        insert!(double, [{1.0, at_minute(1)}, {2.0, at_minute(70)}])
        insert!(enum, [{1, at_minute(1)}, {2, at_minute(70)}])
        insert!(struct, [{%{"temperature" => 1.0, "mode" => 1}, at_minute(1)}])

        refresh_all = fn ->
          Enum.each(SecantService.SecNodes.Reading.AggregateViews.views(), &refresh!/1)
        end

        refresh_all.()

        params = %{
          "reading_numbers" => double,
          "reading_states" => enum,
          "reading_member_numbers" => struct,
          "reading_member_states" => struct
        }

        for {kind, p} <- params, tier <- ["1m", "1h"] do
          assert rows("#{kind}_#{tier}", p) != [], "#{kind}_#{tier} has no rows to delete"
        end

        SecantService.Repo.query!("DELETE FROM parameters WHERE id = ANY($1)", [
          [double.id, enum.id, struct.id]
        ])

        refresh_all.()

        for {kind, p} <- params, tier <- ["1m", "1h"] do
          assert rows("#{kind}_#{tier}", p) == [], "#{kind}_#{tier} still has rows"
        end
      end)
    end

    test "a late reading in an already refreshed bucket appears in both tiers after the next refresh" do
      unboxed(fn ->
        p = parameter!(@double)
        insert!(p, [{1.0, at_minute(5)}])
        refresh!("reading_numbers_1m")
        refresh!("reading_numbers_1h")

        insert!(p, [{9.0, at_minute(5, 30)}])
        refresh!("reading_numbers_1m")
        refresh!("reading_numbers_1h")

        assert [%{"count" => 2, "hi" => [9.0 | _]}] = rows("reading_numbers_1m", p)
        assert [%{"count" => 2, "hi" => [9.0 | _]}] = rows("reading_numbers_1h", p)
      end)
    end
  end

  # reading_member_values(reading, datainfo) as sorted {member, idx, type, v}
  defp member_values(reading, datainfo) do
    unboxed(fn ->
      %{rows: rows} =
        SecantService.Repo.query!(
          "SELECT member, idx, type, v FROM reading_member_values($1::jsonb, $2::jsonb)",
          [reading, datainfo]
        )

      rows |> Enum.map(&List.to_tuple/1) |> Enum.sort()
    end)
  end

  describe "reading_member_values" do
    test "yields scalar members, array elements and array lengths with their types" do
      datainfo = %{
        "type" => "struct",
        "members" => %{
          "t" => @double,
          "modes" => array(@enum),
          "flags" => array(%{"type" => "bool"}),
          "name" => %{"type" => "string"},
          "limits" => %{"type" => "struct", "members" => %{"lo" => @double}}
        }
      }

      reading = %{
        "t" => 1.5,
        "modes" => [0, 2],
        "flags" => [true],
        "name" => "x",
        "limits" => %{"lo" => 0.0},
        "undeclared" => 1
      }

      assert member_values(reading, datainfo) == [
               {"flags", 0, "length", 1},
               {"flags", 1, "bool", true},
               {"modes", 0, "length", 2},
               {"modes", 1, "enum", 0},
               {"modes", 2, "enum", 2},
               {"t", 1, "double", 1.5}
             ]
    end

    test "keys tuple members by 0-based position" do
      datainfo = %{"type" => "tuple", "members" => [@double, @enum]}
      assert member_values([2.5, 1], datainfo) == [{"0", 1, "double", 2.5}, {"1", 1, "enum", 1}]
    end

    test "yields nothing for a reading or member of the wrong shape" do
      struct = %{"type" => "struct", "members" => %{"s" => array(@double)}}
      tuple = %{"type" => "tuple", "members" => [@double]}

      assert member_values([1.0], struct) == []
      assert member_values(%{"0" => 1.0}, tuple) == []
      assert member_values(%{"s" => 5}, struct) == []
      assert member_values(5, struct) == []
      assert member_values(5, tuple) == []
    end
  end

  describe "member views" do
    test "a struct's number, enum and array members, but not its nested struct" do
      unboxed(fn ->
        p = parameter!(@struct)

        insert!(p, [
          {%{
             "temperature" => 1.5,
             "count" => 3,
             "mode" => 1,
             "spectrum" => [1.0, 2.0],
             "limits" => %{"lo" => 0.0}
           }, at(1)}
        ])

        assert member_numbers(p) |> Map.keys() |> Enum.sort() == [
                 {"count", 1},
                 {"spectrum", 0},
                 {"spectrum", 1},
                 {"spectrum", 2},
                 {"temperature", 1}
               ]

        assert %{min: 2.0, max: 2.0} = member_numbers(p)[{"spectrum", 0}]
        assert member_states(p) |> Map.keys() == [{"mode", 1, 1}]
      end)
    end

    test "tuple members are keyed by position" do
      unboxed(fn ->
        p = parameter!(%{"type" => "tuple", "members" => [@double, @enum]})
        insert!(p, [{[2.5, 1], at(1)}])

        assert %{{"0", 1} => %{min: 2.5}} = member_numbers(p)
        assert member_states(p) |> Map.keys() == [{"1", 1, 1}]
      end)
    end

    test "a member with an unexpected value is left out, the others are not" do
      unboxed(fn ->
        p = parameter!(@struct)
        insert!(p, [{%{"temperature" => "hot", "mode" => 1}, at(1)}])
        insert!(p, [{%{"temperature" => 2.0, "mode" => 1}, at(2)}])

        assert %{{"temperature", 1} => %{count: 1}} = member_numbers(p)
        assert %{{"mode", 1, 1} => %{count: 2}} = member_states(p)
      end)
    end

    test "a member nested two levels deep gets no aggregates" do
      unboxed(fn ->
        range = %{"type" => "struct", "members" => %{"lo" => @double}}

        p =
          parameter!(%{
            "type" => "struct",
            "members" => %{"limits" => %{"type" => "struct", "members" => %{"range" => range}}}
          })

        insert!(p, [{%{"limits" => %{"range" => %{"lo" => 1.0}}}, at(1)}])

        assert member_numbers(p) == %{}
        assert member_states(p) == %{}
      end)
    end

    test "member numbers too large or too small for float8 are left out" do
      unboxed(fn ->
        p = parameter!(@struct)

        insert!(p, [
          {%{"temperature" => 1.0}, at(1)},
          {%{"temperature" => Integer.pow(10, 400)}, at(2)}
        ])

        insert_sql!(p, "value_json", ~s|'{"value": {"temperature": 1e-400}}'::jsonb|, at(3))

        assert %{{"temperature", 1} => %{min: 1.0, max: 1.0, count: 1}} = member_numbers(p)
      end)
    end

    test "a fractional int member is left out" do
      unboxed(fn ->
        p = parameter!(@struct)
        insert!(p, [{%{"count" => 2.5}, at(1)}, {%{"count" => 3}, at(2)}])

        assert %{{"count", 1} => %{min: 3.0, count: 1}} = member_numbers(p)
      end)
    end

    test "an int member beyond bigint is left out, as a top-level int would be" do
      unboxed(fn ->
        p = parameter!(@struct)
        insert!(p, [{%{"count" => Integer.pow(10, 20)}, at(1)}, {%{"count" => 3}, at(2)}])

        assert %{{"count", 1} => %{min: 3.0, count: 1}} = member_numbers(p)
      end)
    end

    test "an array member with an element that doesn't fit its type is left out whole" do
      unboxed(fn ->
        p =
          parameter!(%{
            "type" => "struct",
            "members" => %{"ints" => array(@int), "t" => @double}
          })

        insert!(p, [
          {%{"ints" => [1, 2.5], "t" => 1.0}, at(1)},
          {%{"ints" => [4], "t" => 2.0}, at(2)}
        ])

        assert %{{"ints", 0} => %{count: 1}, {"ints", 1} => %{min: 4.0, count: 1}} =
                 numbers = member_numbers(p)

        assert map_size(numbers) == 3
        assert %{{"t", 1} => %{count: 2}} = numbers
      end)
    end

    test "a whole-number float in an integer member counts as an integer" do
      # once in jsonb, 2.0 and 1000.0 (written 1.0e3) can't be told from
      # integers, so every whole number is treated alike
      unboxed(fn ->
        p =
          parameter!(%{
            "type" => "struct",
            "members" => %{"count" => @int, "ints" => array(@int), "mode" => @enum}
          })

        insert!(p, [{%{"count" => 2.0, "ints" => [1, 1000.0], "mode" => 1.0}, at(1)}])
        insert!(p, [{%{"count" => 3, "ints" => [1, 2], "mode" => 1}, at(2)}])

        assert %{
                 {"count", 1} => %{min: 2.0, count: 2},
                 {"ints", 0} => %{count: 2},
                 {"ints", 2} => %{min: 2.0, max: 1000.0}
               } = member_numbers(p)

        assert %{{"mode", 1, 1} => %{count: 2}} = member_states(p)
      end)
    end

    test "the largest double as an exact integer fits a double array member" do
      unboxed(fn ->
        p = parameter!(%{"type" => "struct", "members" => %{"d" => array(@double)}})
        insert!(p, [{%{"d" => [1.0, trunc(1.7976931348623157e308)]}, at(1)}])

        # the array is kept; its huge element is too large to sum
        assert %{{"d", 0} => %{min: 2.0}, {"d", 1} => %{min: 1.0}} = numbers = member_numbers(p)
        refute Map.has_key?(numbers, {"d", 2})
      end)
    end

    test "a subnormal double in an array member is kept" do
      unboxed(fn ->
        p = parameter!(%{"type" => "struct", "members" => %{"d" => array(@double)}})
        insert!(p, [{%{"d" => [1.0, 5.0e-324]}, at(1)}])

        assert %{{"d", 0} => %{min: 2.0}, {"d", 1} => %{min: 1.0}, {"d", 2} => %{min: 5.0e-324}} =
                 member_numbers(p)
      end)
    end

    test "fractional and out-of-range enum members are left out" do
      unboxed(fn ->
        p = parameter!(@struct)

        insert!(p, [
          {%{"mode" => 1.5}, at(1)},
          {%{"mode" => Integer.pow(10, 30)}, at(2)},
          {%{"mode" => 2}, at(3)}
        ])

        assert member_states(p) |> Map.keys() == [{"mode", 1, 2}]
      end)
    end

    test "readings of the wrong shape are left out, and the refresh succeeds" do
      unboxed(fn ->
        struct = parameter!(@struct)
        tuple = parameter!(%{"type" => "tuple", "members" => [@double]})
        insert!(struct, [{[1.0, 2.0], at(1)}, {%{"temperature" => 4.0}, at(2)}])
        insert!(tuple, [{%{"0" => 1.0}, at(1)}, {[5.0], at(2)}])

        assert member_numbers(struct) |> Map.keys() == [{"temperature", 1}]
        assert member_numbers(tuple) |> Map.keys() == [{"0", 1}]
      end)
    end
  end
end
