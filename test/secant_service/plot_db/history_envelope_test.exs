defmodule SecantService.PlotDB.HistoryEnvelopeTest do
  @moduledoc """
  Envelope windows: `History.window/4` with `envelope: true`, reading whole
  buckets from the continuous aggregates. These refresh views, so they run
  outside the sandbox (see `SecantService.AggregateHelpers`).

  A view's watermark never moves back, and the test database keeps it from
  run to run, so each test seeds its readings after the watermark the views
  report when it starts, and refreshes only the range it needs.
  """
  use ExUnit.Case, async: false

  import SecantService.AggregateHelpers

  alias SecantService.PlotDB.Aggregates
  alias SecantService.PlotDB.History
  alias SecantService.PlotDB.History.Envelope
  alias SecantService.Repo

  setup_all :setup_aggregates

  @minute 60_000
  @double %{"type" => "double"}
  # 2 h at 1-minute buckets: 120 buckets
  @opts [envelope: true, max_raw: 50, max_buckets: 120]

  defp ms(%DateTime{} = t), do: DateTime.to_unix(t, :millisecond)

  # a whole hour after the views' watermark and after 2032 (other tests'
  # readings), so the test's buckets have never been materialized
  defp fresh_start do
    t = Aggregates.materialized_until("reading_numbers_1m")

    t =
      if t && DateTime.after?(t, ~U[2032-01-01 00:00:00Z]), do: t, else: ~U[2032-01-01 00:00:00Z]

    %{DateTime.add(t, 2, :hour) | minute: 0, second: 0, microsecond: {0, 6}}
  end

  # a reading every `step_s` seconds over `count` steps from `start`
  defp seed(param, start, count, step_s, value_fun) do
    readings =
      for i <- 0..(count - 1), do: {value_fun.(i), DateTime.add(start, i * step_s, :second)}

    insert!(param, readings)
    readings
  end

  defp refresh(from, to), do: refresh!("reading_numbers_1m", from, to)

  test "a double: band rows from the aggregates, head and tail as today" do
    unboxed(fn ->
      param = parameter!(@double)
      start = fresh_start()
      # every 10 s for 2 h, value = index
      seed(param, start, 719, 10, &(&1 * 1.0))
      # the last reading has a fraction of a millisecond
      last_at = DateTime.add(start, 7_195_000_700, :microsecond)
      insert!(param, [{-1.0, last_at}])
      refresh(start, DateTime.add(start, 1, :hour))

      window = History.window(param, ms(start), ms(start) + 2 * 3_600_000, @opts)

      assert %{bucket_ms: @minute, from_ms: from_ms, until_ms: until_ms, rows: rows} =
               window.envelope

      assert from_ms == ms(start)
      assert until_ms == ms(start) + 3_600_000
      assert length(rows) == 60

      # bucket 0 holds the readings at 0, 10, ... 50 s: values 0..5
      assert [t0, +0.0, mean0, 5.0] = hd(rows)
      assert t0 == ms(start) + 30_000
      assert_in_delta mean0, 2.5, 1.0e-9

      # the mean points are in the line, at the rows' times
      points = Enum.zip(window.timestamps, window.values)
      assert {t0, mean0} in points

      # the window starts at its first reading and ends at its last
      assert hd(window.timestamps) == ms(start)
      assert List.last(window.timestamps) == ms(last_at)
      assert {ms(last_at), -1.0} in points

      # the tail after the materialized hour is today's thinned line: raw
      # readings, not means
      assert Enum.any?(points, fn {t, v} -> t > until_ms and v == 396.0 end)
    end)
  end

  test "a first reading after the first bucket's centre starts the line" do
    unboxed(fn ->
      param = parameter!(@double)
      start = fresh_start()
      first = DateTime.add(start, 40, :second)
      seed(param, first, 712, 10, &(&1 * 1.0))
      refresh(start, DateTime.add(start, 2, :hour))

      window = History.window(param, ms(start), ms(start) + 2 * 3_600_000, @opts)

      assert [[t0 | _] | _] = window.envelope.rows
      # the first bucket's only readings lie at 40 and 50 s: its point moves to 40 s
      assert t0 == ms(first)
      assert hd(window.timestamps) == ms(first)
    end)
  end

  test "unaligned edges: partial buckets stay readings, a spike outside is in no row" do
    unboxed(fn ->
      param = parameter!(@double)
      start = fresh_start()
      seed(param, start, 720, 10, fn _ -> 1.0 end)
      # a spike before the window, inside the window's first partial bucket
      insert!(param, [{1000.0, DateTime.add(start, 65, :second)}])
      refresh(start, DateTime.add(start, 2, :hour))

      from = ms(start) + 90_000
      to = from + 2 * 3_600_000 - 60_000
      window = History.window(param, from, to, @opts)

      assert window.envelope.from_ms == ms(start) + 120_000
      refute Enum.any?(window.envelope.rows, fn [_t, _min, _mean, max] -> max == 1000.0 end)
      # the head [from, a) holds the readings at 90..110 s
      assert hd(window.timestamps) == from
      assert Enum.all?(window.timestamps, &(&1 >= from and &1 <= to))
    end)
  end

  test "the edges match time_bucket for a 2-day width" do
    unboxed(fn ->
      w = 2 * 86_400_000
      from = ~U[2031-05-07 13:21:05.000000Z]
      to = ~U[2031-06-11 01:02:03.000000Z]

      %{rows: [[floor_from, floor_to]]} =
        Repo.query!(
          "SELECT time_bucket('2 days'::interval, $1::timestamp), time_bucket('2 days'::interval, $2::timestamp)",
          [DateTime.to_naive(from), DateTime.to_naive(to)]
        )

      to_ms = &(&1 |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond))
      assert Envelope.edges(ms(from), ms(to), w) == {to_ms.(floor_from) + w, to_ms.(floor_to)}
    end)
  end

  test "an array: 0-based rows, one mean array per bucket, a whole last reading" do
    unboxed(fn ->
      param =
        parameter!(%{
          "type" => "array",
          "minlen" => 1,
          "maxlen" => 3,
          "members" => %{"type" => "double"}
        })

      start = fresh_start()
      seed(param, start, 719, 10, fn i -> [i * 1.0, 1.0, 2.0] end)
      # the window's last reading is shorter than the one before it
      last_at = DateTime.add(start, 7_195, :second)
      insert!(param, [{[7.0, 8.0], last_at}])
      refresh(start, DateTime.add(start, 2, :hour))

      window = History.window(param, ms(start), ms(start) + 2 * 3_600_000, @opts)

      assert [[t0, 0, +0.0, _mean, 5.0], [t0, 1, 1.0, 1.0, 1.0], [t0, 2, 2.0, 2.0, 2.0] | _] =
               window.envelope.rows

      refute Enum.any?(window.envelope.rows, fn [_t, i | _] -> i < 0 end)

      assert {^t0, [_, 1.0, 2.0]} =
               Enum.find(Enum.zip(window.timestamps, window.values), &(elem(&1, 0) == t0))

      # the tail is empty: the edge point is the last stored reading, whole
      assert List.last(window.values) == [7.0, 8.0]
      assert List.last(window.timestamps) == ms(last_at)
    end)
  end

  test "an element missing from a bucket leaves a hole in its mean array" do
    unboxed(fn ->
      param =
        parameter!(%{"type" => "array", "maxlen" => 3, "members" => %{"type" => "double"}})

      start = fresh_start()
      seed(param, DateTime.add(start, 60, :second), 713, 10, fn _ -> [1.0, 2.0, 3.0] end)
      # bucket 0: element 3 is NaN in every reading, so it has no row there
      for s <- [0, 10, 20] do
        insert_sql!(
          param,
          "value_float_array",
          "ARRAY[1, 2, 'NaN']::float8[]",
          DateTime.add(start, s, :second)
        )
      end

      refresh(start, DateTime.add(start, 2, :hour))

      window = History.window(param, ms(start), ms(start) + 2 * 3_600_000, @opts)
      [[t0 | _] | _] = window.envelope.rows

      assert {t0, [1.0, 2.0, nil]} in Enum.zip(window.timestamps, window.values)
    end)
  end

  test "a window past the watermark is today's window" do
    unboxed(fn ->
      param = parameter!(@double)
      start = fresh_start()
      seed(param, start, 720, 10, &(&1 * 1.0))

      from = ms(start)
      to = from + 2 * 3_600_000
      window = History.window(param, from, to, @opts)

      assert window.envelope == nil

      assert Map.delete(window, :envelope) ==
               History.window(param, from, to, Keyword.delete(@opts, :envelope))
    end)
  end

  test "sub-minute and raw plans get no envelope" do
    unboxed(fn ->
      param = parameter!(@double)
      start = fresh_start()
      seed(param, start, 720, 10, &(&1 * 1.0))
      refresh(start, DateTime.add(start, 2, :hour))
      from = ms(start)
      to = from + 2 * 3_600_000

      # 2 h over 400 buckets: 30-second buckets
      sub_minute = History.window(param, from, to, envelope: true, max_raw: 50, max_buckets: 400)
      assert sub_minute.bucket_ms == 30_000
      assert sub_minute.envelope == nil

      raw = History.window(param, from, to, envelope: true, max_raw: 10_000)
      refute raw.aggregated
      assert raw.envelope == nil
    end)
  end
end
