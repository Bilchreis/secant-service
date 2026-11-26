defmodule SecantService.PlotDB.Aggregates do
  @moduledoc """
  A parameter's per-bucket summaries for a time window, read from the
  continuous aggregates over `readings` (see the "Aggregates" section of
  `SecantService.SecNodes.Reading`).

  `numbers/4` returns min, max, mean, first and last per bucket for the
  parameter's numbers: a number, each element and the length (`idx` 0) of
  an array, or each number member of a struct or tuple. `states/4` returns
  one entry per state that occurs per bucket for enums and bools. Either is
  one query.

  The bucket width must be a whole number of minutes. It is rolled up from
  the 1-hour views when it is a whole number of hours, else from the
  1-minute views. The window `[from, to)` is normalized by flooring both
  edges to the width, and only buckets that lie fully inside it and end by
  `materialized_until` are returned.

  `materialized_until` is the view's high-water mark: no bucket after it has
  been materialized yet. It does not promise that the buckets before it are
  current; a late reading or a delete appears after the next refresh. It is
  `nil` while a view has never been refreshed.

  Nothing reads these yet; the plots switch over in a later change.
  """

  alias SecantService.Repo
  alias SecantService.SecNodes.Parameter

  @minute_ms 60_000
  @hour_ms 60 * @minute_ms

  @number_types ~w(double int scaled)
  @state_types ~w(enum bool)

  # what TimescaleDB's watermark reports for a view that was never refreshed
  # (4714-11-24 BC, in Unix microseconds)
  @no_watermark -210_866_803_200_000_000

  @type tier :: :minute | :hour
  @type result :: %{
          tier: tier,
          materialized_until: DateTime.t() | nil,
          buckets: [map]
        }

  @doc """
  Number buckets of `param` for `[from_ms, to_ms)` (Unix milliseconds) at
  `bucket_ms` wide buckets. Each bucket is a map with `bucket`, `member` (nil
  outside structs and tuples), `idx`, `min`, `min_at`, `max`, `max_at`,
  `mean`, `count`, `first`, `first_at`, `last` and `last_at`.
  """
  @spec numbers(Parameter.t(), integer, integer, pos_integer) ::
          {:ok, result} | {:error, :unsupported_width | :not_aggregated}
  def numbers(%Parameter{} = param, from_ms, to_ms, bucket_ms) do
    with {:ok, tier} <- tier(bucket_ms),
         {:ok, kind} <- number_kind(param.datainfo) do
      read(kind, tier, param, from_ms, to_ms, bucket_ms)
    end
  end

  @doc """
  State buckets of `param`, as `numbers/4` takes them. Each bucket is a map
  with `bucket`, `member`, `idx`, `state`, `first_at`, `last_at` and `count`,
  one per state that occurs in the bucket. Bools read as 0 and 1.
  """
  @spec states(Parameter.t(), integer, integer, pos_integer) ::
          {:ok, result} | {:error, :unsupported_width | :not_aggregated}
  def states(%Parameter{} = param, from_ms, to_ms, bucket_ms) do
    with {:ok, tier} <- tier(bucket_ms),
         {:ok, kind} <- state_kind(param.datainfo) do
      read(kind, tier, param, from_ms, to_ms, bucket_ms)
    end
  end

  @doc """
  The high-water mark of a view (`"reading_numbers_1m"`, say) as a
  `DateTime`, or nil if it was never refreshed. Raises for a name that is
  not a continuous aggregate. Reads the watermark the same way `numbers/4`
  and `states/4` do.
  """
  @spec materialized_until(String.t()) :: DateTime.t() | nil
  # the SQL interpolates only view and function names from this module
  # sobelow_skip ["SQL.Query"]
  def materialized_until(view) when is_binary(view) do
    %{rows: [[until]]} = Repo.query!("SELECT #{watermark("$1::text")}", [view])
    decode_watermark(until)
  end

  @doc false
  # A watermark in Unix microseconds, as a DateTime; nil for the sentinel of
  # a view that was never refreshed.
  def decode_watermark(us) when is_integer(us) and us <= @no_watermark, do: nil
  def decode_watermark(us) when is_integer(us), do: DateTime.from_unix!(us, :microsecond)

  # -- which view --------------------------------------------------------------

  defp tier(bucket_ms) when is_integer(bucket_ms) and bucket_ms > 0 do
    cond do
      rem(bucket_ms, @hour_ms) == 0 -> {:ok, :hour}
      rem(bucket_ms, @minute_ms) == 0 -> {:ok, :minute}
      true -> {:error, :unsupported_width}
    end
  end

  defp tier(_bucket_ms), do: {:error, :unsupported_width}

  # A parameter has number aggregates if it is a number, or an array of
  # anything aggregated (its length is a number), or a struct or tuple with
  # such a member; state aggregates if it is an enum or bool, an array of
  # them, or a struct or tuple with such a member.
  defp number_kind(%{"type" => type} = datainfo) when type in ~w(struct tuple),
    do: if(Enum.any?(members(datainfo), &number?/1), do: {:ok, :member_numbers}, else: none())

  defp number_kind(datainfo), do: if(number?(datainfo), do: {:ok, :numbers}, else: none())

  defp state_kind(%{"type" => type} = datainfo) when type in ~w(struct tuple),
    do: if(Enum.any?(members(datainfo), &state?/1), do: {:ok, :member_states}, else: none())

  defp state_kind(datainfo), do: if(state?(datainfo), do: {:ok, :states}, else: none())

  defp none, do: {:error, :not_aggregated}

  defp number?(%{"type" => type}) when type in @number_types, do: true

  defp number?(%{"type" => "array", "members" => %{"type" => type}}),
    do: type in @number_types or type in @state_types

  defp number?(_datainfo), do: false

  defp state?(%{"type" => type}) when type in @state_types, do: true
  defp state?(%{"type" => "array", "members" => %{"type" => type}}), do: type in @state_types
  defp state?(_datainfo), do: false

  # the direct members' datainfos: a struct's by name, a tuple's by position
  defp members(%{"members" => members}) when is_map(members), do: Map.values(members)
  defp members(%{"members" => members}) when is_list(members), do: members
  defp members(_datainfo), do: []

  # view name prefix, group keys, and the rollup of each kind (design
  # decision 5 of add-reading-aggregates)
  defp kind(:numbers), do: {"reading_numbers", ["idx"], &number_rollup/0}
  defp kind(:member_numbers), do: {"reading_member_numbers", ["member", "idx"], &number_rollup/0}
  defp kind(:states), do: {"reading_states", ["idx", "state"], &state_rollup/0}

  defp kind(:member_states),
    do: {"reading_member_states", ["member", "idx", "state"], &state_rollup/0}

  defp number_rollup do
    """
    min(lo) AS lo, max(hi) AS hi, sum(sum) AS sum, sum(count)::bigint AS count,
    min(first_key) AS first_key, max(last_key) AS last_key
    """
  end

  defp state_rollup do
    "min(first_at) AS first_at, max(last_at) AS last_at, sum(count)::bigint AS count"
  end

  # -- the query ---------------------------------------------------------------

  # One query: the watermark, and the rolled-up buckets that end by it. The
  # LEFT JOIN keeps the watermark row when there are no buckets. For the
  # 1-hour tier the 1-minute view's watermark counts too, since the hourly
  # view is built from it.
  # sobelow_skip ["SQL.Query"]
  defp read(kind, tier, param, from_ms, to_ms, bucket_ms) do
    {prefix, keys, rollup} = kind(kind)
    view = prefix <> if(tier == :hour, do: "_1h", else: "_1m")
    keys_sql = Enum.join(keys, ", ")

    until =
      case tier do
        :hour -> "LEAST(#{watermark("'#{view}'")}, #{watermark("'#{prefix}_1m'")})"
        :minute -> watermark("'#{view}'")
      end

    # `w` is MATERIALIZED and read through a scalar subquery, so the watermark
    # is computed once: as a join condition the planner pushed it into the
    # scan and computed it for every row (175 s instead of 2.5 s for the
    # bench's 1000-element array).
    sql = """
    WITH w AS MATERIALIZED (SELECT #{until} AS until),
    b AS (
      SELECT time_bucket($2::interval, bucket) AS start, #{keys_sql}, #{rollup.()}
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

    %{columns: [_until | columns], rows: rows} =
      Repo.query!(sql, [
        param.id,
        %Postgrex.Interval{secs: div(bucket_ms, 1000)},
        to_naive(from_ms),
        to_naive(to_ms)
      ])

    [[until | _] | _] = rows

    buckets =
      for [_until | [start | _] = row] <- rows, start != nil do
        columns |> Enum.zip(row) |> Map.new() |> bucket(kind)
      end

    {:ok, %{tier: tier, materialized_until: decode_watermark(until), buckets: buckets}}
  end

  defp watermark(view_sql) do
    """
    _timescaledb_functions.cagg_watermark(
      (SELECT mat_hypertable_id FROM _timescaledb_catalog.continuous_agg
       WHERE user_view_name = #{view_sql}))\
    """
  end

  defp bucket(row, kind) when kind in [:numbers, :member_numbers] do
    [min, min_at, _] = row["lo"]
    [max, neg_max_at, _] = row["hi"]
    [first_at, _, first] = row["first_key"]
    [last_at, _, last] = row["last_key"]

    %{
      bucket: utc(row["start"]),
      member: row["member"],
      idx: row["idx"],
      min: min,
      min_at: from_us(min_at),
      max: max,
      max_at: from_us(-neg_max_at),
      # the mean in Elixir: in SQL a sum of tiny values divided by the
      # count can underflow and raise
      mean: row["sum"] / row["count"],
      count: row["count"],
      first: first,
      first_at: from_us(first_at),
      last: last,
      last_at: from_us(last_at)
    }
  end

  defp bucket(row, _states) do
    %{
      bucket: utc(row["start"]),
      member: row["member"],
      idx: row["idx"],
      state: row["state"],
      first_at: utc(row["first_at"]),
      last_at: utc(row["last_at"]),
      count: row["count"]
    }
  end

  defp from_us(us), do: us |> trunc() |> DateTime.from_unix!(:microsecond)
  defp utc(%NaiveDateTime{} = t), do: DateTime.from_naive!(t, "Etc/UTC")

  defp to_naive(ms) do
    ms |> trunc() |> DateTime.from_unix!(:millisecond) |> DateTime.to_naive()
  end
end
