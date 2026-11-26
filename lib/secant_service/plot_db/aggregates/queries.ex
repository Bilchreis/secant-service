defmodule SecantService.PlotDB.Aggregates.Queries do
  @moduledoc false
  # The SQL that `SecantService.PlotDB.Aggregates` runs. `Aggregates` builds
  # every variant from these functions when it compiles, so its queries are
  # fixed strings, and the parameter, width and window are always parameters.

  @doc "The watermark of the view named by parameter $1, in Unix microseconds."
  def watermark, do: "SELECT " <> watermark_of("$1::text")

  @doc """
  The rollup of `kind` at `tier` for the window, with the view's watermark.
  Parameters: $1 the parameter id, $2 the bucket width (interval), $3 and $4
  the window's start and end (timestamps).
  """
  def read(kind, tier) do
    {prefix, keys, rollup} = kind(kind)
    view = prefix <> if(tier == :hour, do: "_1h", else: "_1m")
    keys_sql = Enum.join(keys, ", ")

    # for the 1-hour tier the 1-minute view's watermark counts too, since the
    # hourly view is built from it
    until =
      case tier do
        :hour -> "LEAST(#{watermark_of("'#{view}'")}, #{watermark_of("'#{prefix}_1m'")})"
        :minute -> watermark_of("'#{view}'")
      end

    # The LEFT JOIN keeps the watermark row when there are no buckets. `w` is
    # MATERIALIZED and read through a scalar subquery, so the watermark is
    # computed once: as a join condition the planner pushed it into the scan
    # and computed it for every row (175 s instead of 2.5 s for the bench's
    # 1000-element array).
    """
    WITH w AS MATERIALIZED (SELECT #{until} AS until),
    b AS (
      SELECT time_bucket($2::interval, bucket) AS start, #{keys_sql}, #{rollup}
      FROM #{view}
      WHERE parameter_id = $1
        AND bucket >= time_bucket($2::interval, $3::timestamp)
        AND bucket < time_bucket($2::interval, $4::timestamp)
        AND time_bucket($2::interval, bucket) + $2::interval
          <= (SELECT _timescaledb_functions.to_timestamp_without_timezone(until) FROM w)
      GROUP BY start, #{keys_sql}
    )
    SELECT w.until, b.*
    FROM w
    LEFT JOIN b ON true
    ORDER BY b.start, #{keys_sql}
    """
  end

  # view name prefix, group keys, and the rollup of each kind (design
  # decision 5 of add-reading-aggregates)
  defp kind(:numbers), do: {"reading_numbers", ["idx"], number_rollup()}
  defp kind(:member_numbers), do: {"reading_member_numbers", ["member", "idx"], number_rollup()}
  defp kind(:states), do: {"reading_states", ["idx", "state"], state_rollup()}

  defp kind(:member_states),
    do: {"reading_member_states", ["member", "idx", "state"], state_rollup()}

  defp number_rollup do
    """
    min(lo) AS lo, max(hi) AS hi, sum(sum) AS sum, sum(count)::bigint AS count,
    min(first_key) AS first_key, max(last_key) AS last_key
    """
  end

  defp state_rollup do
    "min(first_at) AS first_at, max(last_at) AS last_at, sum(count)::bigint AS count"
  end

  defp watermark_of(view_sql) do
    """
    _timescaledb_functions.cagg_watermark(
      (SELECT mat_hypertable_id FROM _timescaledb_catalog.continuous_agg
       WHERE user_view_name = #{view_sql}))\
    """
  end
end
