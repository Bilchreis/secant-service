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

  The historical plots read them for envelope windows (see "Envelope" in
  `SecantService.PlotDB.History`).
  """

  alias SecantService.PlotDB.Aggregates.Queries
  alias SecantService.Repo
  alias SecantService.SecNodes.Parameter

  # the queries, built from Aggregates.Queries when this module compiles
  @numbers_1m Queries.read(:numbers, :minute)
  @numbers_1h Queries.read(:numbers, :hour)
  @member_numbers_1m Queries.read(:member_numbers, :minute)
  @member_numbers_1h Queries.read(:member_numbers, :hour)
  @states_1m Queries.read(:states, :minute)
  @states_1h Queries.read(:states, :hour)
  @member_states_1m Queries.read(:member_states, :minute)
  @member_states_1h Queries.read(:member_states, :hour)
  @watermark_query Queries.watermark()

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
  def materialized_until(view) when is_binary(view) do
    %{rows: [[until]]} = Repo.query!(@watermark_query, [view])
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

  # -- the query ---------------------------------------------------------------

  # One query: the watermark, and the rolled-up buckets that end by it (see
  # Aggregates.Queries). The SQL of every kind and tier is built when this
  # module compiles; only the parameter, width and window are parameters.
  defp read(kind, tier, param, from_ms, to_ms, bucket_ms) do
    %{columns: [_until | columns], rows: rows} =
      run(kind, tier, [
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

  # Each query is a module attribute in the call, so it is a fixed string
  # (and Sobelow can see it is one).
  defp run(:numbers, :minute, params), do: Repo.query!(@numbers_1m, params)
  defp run(:numbers, :hour, params), do: Repo.query!(@numbers_1h, params)
  defp run(:member_numbers, :minute, params), do: Repo.query!(@member_numbers_1m, params)
  defp run(:member_numbers, :hour, params), do: Repo.query!(@member_numbers_1h, params)
  defp run(:states, :minute, params), do: Repo.query!(@states_1m, params)
  defp run(:states, :hour, params), do: Repo.query!(@states_1h, params)
  defp run(:member_states, :minute, params), do: Repo.query!(@member_states_1m, params)
  defp run(:member_states, :hour, params), do: Repo.query!(@member_states_1h, params)

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
