defmodule SecantService.PlotDB.History.Envelope do
  @moduledoc """
  The arithmetic of an envelope window (see `SecantService.PlotDB.History`),
  on integer Unix milliseconds.

  A window `[from, to]` drawn at bucket width `w` splits into:

    * the head `[from, a)`, before the first whole bucket;
    * the middle `[a, until)`, whole buckets read from the aggregates;
    * the tail `[until, to]`, after the last whole bucket that is both inside
      the window and materialized.

  Bucket boundaries follow `time_bucket`'s default origin, Monday
  2000-01-03 00:00 UTC, so they match the buckets the aggregates roll up to,
  also for widths of several days. Floor division keeps instants before the
  origin (and before 1970) on the same grid.
  """

  # 2000-01-03 00:00:00 UTC, time_bucket's default origin
  @origin_ms 946_857_600_000

  @doc """
  `{a, b}`: the first bucket boundary at or after `from_ms` and the last at
  or before `to_ms`. The window holds no whole bucket when `a >= b`.
  """
  @spec edges(integer, integer, pos_integer) :: {integer, integer}
  def edges(from_ms, to_ms, width_ms) do
    {ceil_to(from_ms, width_ms), floor_to(to_ms, width_ms)}
  end

  @doc """
  The end of the aggregated middle: the materialized point floored to a
  bucket boundary, kept within `[a, b]`. `a` (an empty middle) while the
  aggregates were never refreshed.
  """
  @spec until(integer, integer, integer | nil, pos_integer) :: integer
  def until(a, _b, nil, _width_ms), do: a

  def until(a, b, materialized_ms, width_ms),
    do: materialized_ms |> floor_to(width_ms) |> min(b) |> max(a)

  @doc """
  Where a bucket's point is drawn: at its centre, moved into the span of
  the bucket's own readings (`first_ms`..`last_ms`), so no point lies
  before the first or after the last reading of a window.
  """
  @spec point_time(integer, pos_integer, integer, integer) :: integer
  def point_time(bucket_ms, width_ms, first_ms, last_ms) do
    (bucket_ms + div(width_ms, 2)) |> max(first_ms) |> min(last_ms)
  end

  @doc "`ms` floored to a bucket boundary of `width_ms`."
  def floor_to(ms, width_ms),
    do: @origin_ms + Integer.floor_div(ms - @origin_ms, width_ms) * width_ms

  defp ceil_to(ms, width_ms) do
    floored = floor_to(ms, width_ms)
    if floored == ms, do: ms, else: floored + width_ms
  end
end
