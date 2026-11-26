defmodule SecantService.PlotDB.AggregatesTest do
  @moduledoc """
  Reading the continuous aggregates for a window. These refresh views, so
  they run outside the sandbox (see `SecantService.AggregateHelpers`).

  A view's watermark never moves back, and the test database keeps it from
  run to run, so each test uses its own time range and checks windows
  against the `materialized_until` the call returns.
  """
  use ExUnit.Case, async: false

  import SecantService.AggregateHelpers

  alias SecantService.PlotDB.Aggregates

  setup_all :setup_aggregates

  @minute_ms 60_000
  @double %{"type" => "double"}

  defp ms(%DateTime{} = t), do: DateTime.to_unix(t, :millisecond)

  # the next whole hour after `t`, and after 2032 (other tests' readings)
  defp next_hour(t) do
    t =
      if t && DateTime.after?(t, ~U[2032-01-01 00:00:00Z]), do: t, else: ~U[2032-01-01 00:00:00Z]

    %{DateTime.add(t, 1, :hour) | minute: 0, second: 0, microsecond: {0, 6}}
  end

  # `count` readings of `param`, `step_s` apart from `start`, with values
  # from `value_fun`; returns them as {value, time}
  defp seed(param, start, count, step_s, value_fun) do
    readings =
      for i <- 0..(count - 1), do: {value_fun.(i), DateTime.add(start, i * step_s, :second)}

    insert!(param, readings)
    readings
  end

  # The buckets computed in Elixir from the raw readings, as `numbers/4`
  # returns them for a scalar.
  defp expected_buckets(readings, start, width_ms) do
    readings
    |> Enum.group_by(fn {_v, t} -> div(ms(t) - ms(start), width_ms) end)
    |> Enum.sort()
    |> Enum.map(fn {n, in_bucket} ->
      # readings are in time order, so ties go to the earliest
      {min, min_at} = Enum.min_by(in_bucket, &elem(&1, 0))
      {max, max_at} = Enum.max_by(in_bucket, &elem(&1, 0))
      {first, first_at} = List.first(in_bucket)
      {last, last_at} = List.last(in_bucket)
      values = Enum.map(in_bucket, &elem(&1, 0))

      %{
        bucket: DateTime.add(start, n * width_ms, :millisecond),
        min: min,
        min_at: min_at,
        max: max,
        max_at: max_at,
        mean: Enum.sum(values) / length(values),
        count: length(values),
        first: first,
        first_at: first_at,
        last: last,
        last_at: last_at
      }
    end)
  end

  defp assert_same_buckets(expected, actual) do
    assert length(actual) == length(expected)

    for {want, got} <- Enum.zip(expected, actual) do
      assert Map.drop(got, [:mean, :member, :idx]) == Map.delete(want, :mean)
      assert_in_delta got.mean, want.mean, 1.0e-9
    end
  end

  defp refresh_numbers do
    refresh!("reading_numbers_1m")
    refresh!("reading_numbers_1h")
  end

  test "15-minute buckets over 72 h equal those computed from the raw readings" do
    unboxed(fn ->
      start = ~U[2029-01-01 00:00:00.000000Z]
      p = parameter!(@double)
      readings = seed(p, start, 864, 300, &(:math.sin(&1 / 9) * 100))
      to = DateTime.add(start, 72, :hour)
      # a reading at `to`, outside the window, so the watermark passes the
      # window's last bucket however empty the test database is
      insert!(p, [{0.0, to}])
      refresh_numbers()

      assert {:ok, result} = Aggregates.numbers(p, ms(start), ms(to), 15 * @minute_ms)
      assert result.tier == :minute
      assert length(result.buckets) == 288
      assert_same_buckets(expected_buckets(readings, start, 15 * @minute_ms), result.buckets)
    end)
  end

  test "a whole number of hours is rolled up from the 1-hour tier" do
    unboxed(fn ->
      start = ~U[2029-02-01 00:00:00.000000Z]
      p = parameter!(@double)
      readings = seed(p, start, 864, 300, &(:math.cos(&1 / 7) * 10))
      to = DateTime.add(start, 72, :hour)
      insert!(p, [{0.0, to}])
      refresh_numbers()

      assert {:ok, result} = Aggregates.numbers(p, ms(start), ms(to), 6 * 60 * @minute_ms)
      assert result.tier == :hour
      assert length(result.buckets) == 12
      assert_same_buckets(expected_buckets(readings, start, 6 * 60 * @minute_ms), result.buckets)
    end)
  end

  test "widths below a tier, or not a whole number of minutes, are rejected" do
    p = %SecantService.SecNodes.Parameter{id: 0, datainfo: @double}

    assert Aggregates.numbers(p, 0, 1, 30_000) == {:error, :unsupported_width}
    assert Aggregates.numbers(p, 0, 1, 90_000) == {:error, :unsupported_width}
    assert Aggregates.states(p, 0, 1, 0) == {:error, :unsupported_width}
  end

  defp param(datainfo), do: %SecantService.SecNodes.Parameter{id: 0, datainfo: datainfo}

  test "a kind of aggregate the parameter does not have is an error" do
    enum = %{"type" => "enum"}
    string = %{"type" => "string"}
    tuple_of_doubles = %{"type" => "tuple", "members" => [@double, @double]}
    struct_of_strings = %{"type" => "struct", "members" => %{"name" => string}}

    for datainfo <- [enum, string, struct_of_strings] do
      assert Aggregates.numbers(param(datainfo), 0, 1, @minute_ms) == {:error, :not_aggregated}
    end

    for datainfo <- [@double, tuple_of_doubles, struct_of_strings] do
      assert Aggregates.states(param(datainfo), 0, 1, @minute_ms) == {:error, :not_aggregated}
    end
  end

  test "a struct's members and an array's elements are read with their member and idx" do
    unboxed(fn ->
      start = ~U[2029-07-01 00:00:00.000000Z]

      struct =
        parameter!(%{
          "type" => "struct",
          "members" => %{
            "temperature" => @double,
            "mode" => %{"type" => "enum", "members" => %{"a" => 0, "b" => 1}},
            "flags" => %{"type" => "array", "members" => %{"type" => "bool"}}
          }
        })

      array = parameter!(%{"type" => "array", "members" => @double})

      seed(
        struct,
        start,
        30,
        60,
        &%{"temperature" => &1 * 1.0, "mode" => rem(&1, 2), "flags" => [true]}
      )

      seed(array, start, 30, 60, &[&1 * 1.0, -(&1 + 1) * 1.0])

      for view <- ~w(reading_numbers_1m reading_member_numbers_1m reading_member_states_1m),
          do: refresh!(view)

      to = DateTime.add(start, 30, :minute)
      keys = fn buckets, fields -> buckets |> Enum.map(&Map.take(&1, fields)) |> Enum.sort() end

      assert {:ok, %{buckets: numbers}} =
               Aggregates.numbers(struct, ms(start), ms(to), 30 * @minute_ms)

      assert keys.(numbers, [:member, :idx]) == [
               %{member: "flags", idx: 0},
               %{member: "temperature", idx: 1}
             ]

      assert %{min: +0.0, max: 29.0, count: 30} =
               Enum.find(numbers, &(&1.member == "temperature"))

      assert {:ok, %{buckets: states}} =
               Aggregates.states(struct, ms(start), ms(to), 30 * @minute_ms)

      assert keys.(states, [:member, :idx, :state, :count]) ==
               [
                 %{member: "flags", idx: 1, state: 1, count: 30},
                 %{member: "mode", idx: 1, state: 0, count: 15},
                 %{member: "mode", idx: 1, state: 1, count: 15}
               ]
               |> Enum.sort()

      assert {:ok, %{buckets: elements}} =
               Aggregates.numbers(array, ms(start), ms(to), 30 * @minute_ms)

      assert for(b <- Enum.sort_by(elements, & &1.idx), do: {b.member, b.idx, b.min, b.max}) == [
               {nil, 0, 2.0, 2.0},
               {nil, 1, +0.0, 29.0},
               {nil, 2, -30.0, -1.0}
             ]
    end)
  end

  test "an unaligned window is normalized, and only whole buckets are returned" do
    unboxed(fn ->
      hour = ~U[2029-03-01 10:00:00.000000Z]
      p = parameter!(@double)
      seed(p, hour, 240, 30, &(&1 * 1.0))
      refresh_numbers()

      from = DateTime.add(hour, 7, :minute)
      to = DateTime.add(hour, 112, :minute)
      assert {:ok, %{buckets: buckets}} = Aggregates.numbers(p, ms(from), ms(to), 15 * @minute_ms)

      assert Enum.map(buckets, & &1.bucket) ==
               for(m <- [0, 15, 30, 45, 60, 75, 90], do: DateTime.add(hour, m, :minute))
    end)
  end

  test "materialized_until is the newest materialized bucket's end, and no bucket past it is returned" do
    unboxed(fn ->
      # after every bucket materialized so far, so this test's refresh moves
      # the watermark (it never moves back, and the test database keeps it)
      start = next_hour(Aggregates.materialized_until("reading_numbers_1m"))
      p = parameter!(@double)
      seed(p, start, 22, 60, &(&1 * 1.0))
      refresh!("reading_numbers_1m")

      until = DateTime.add(start, 22, :minute)
      assert Aggregates.materialized_until("reading_numbers_1m") == until

      to = DateTime.add(start, 1, :hour)
      assert {:ok, result} = Aggregates.numbers(p, ms(start), ms(to), 15 * @minute_ms)
      assert result.materialized_until == until
      # 15:00-30:00 holds readings up to minute 21, but ends after the watermark
      assert [%{bucket: ^start, count: 15}] = result.buckets
    end)
  end

  test "states are rolled up per state" do
    unboxed(fn ->
      start = ~U[2029-05-01 00:00:00.000000Z]
      p = parameter!(%{"type" => "enum", "members" => %{"off" => 0, "on" => 1}})
      seed(p, start, 60, 60, &rem(&1, 2))
      refresh!("reading_states_1m")

      to = DateTime.add(start, 1, :hour)
      assert {:ok, %{buckets: buckets}} = Aggregates.states(p, ms(start), ms(to), 30 * @minute_ms)

      assert for(b <- buckets, do: {DateTime.diff(b.bucket, start, :minute), b.state, b.count}) ==
               [{0, 0, 15}, {0, 1, 15}, {30, 0, 15}, {30, 1, 15}]

      assert hd(buckets).first_at == start
    end)
  end

  test "a view that was never refreshed has no materialized end" do
    unboxed(fn ->
      # a fixed name, so a run killed before the drop is cleaned up by the next
      view = "test_never_refreshed_1m"
      SecantService.Repo.query!("DROP MATERIALIZED VIEW IF EXISTS #{view}")

      SecantService.Repo.query!("""
      CREATE MATERIALIZED VIEW #{view}
      WITH (timescaledb.continuous) AS
      SELECT parameter_id, time_bucket(INTERVAL '1 minute', "timestamp") AS bucket, count(*)
      FROM readings GROUP BY parameter_id, bucket
      WITH NO DATA
      """)

      try do
        assert Aggregates.materialized_until(view) == nil
      after
        SecantService.Repo.query!("DROP MATERIALIZED VIEW #{view}")
      end
    end)
  end

  test "the never-refreshed sentinel decodes to nil" do
    assert Aggregates.decode_watermark(-210_866_803_200_000_000) == nil
    assert Aggregates.decode_watermark(0) == ~U[1970-01-01 00:00:00.000000Z]
  end

  test "one call is one query" do
    unboxed(fn ->
      start = ~U[2029-06-01 00:00:00.000000Z]
      p = parameter!(@double)
      seed(p, start, 60, 60, &(&1 * 1.0))
      refresh!("reading_numbers_1m")

      ref = make_ref()
      test_pid = self()
      id = "aggregates-#{inspect(ref)}"

      # only this process's queries: the handler sees every process's
      :telemetry.attach(
        id,
        [:secant_service, :repo, :query],
        fn _event, _measurements, _meta, _ ->
          if self() == test_pid, do: send(test_pid, {ref, :query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      result = Aggregates.numbers(p, ms(start), ms(DateTime.add(start, 1, :hour)), @minute_ms)
      :telemetry.detach(id)

      assert {:ok, %{buckets: [_ | _]}} = result
      assert_received {^ref, :query}
      refute_received {^ref, :query}
    end)
  end
end
