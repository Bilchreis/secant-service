defmodule SecantService.PlotDB.History do
  @moduledoc """
  Readings of a numeric parameter for the historical plots, thinned out in the
  database when a time window holds more than a chart can show.

  A window with up to `max_raw` readings is returned as stored. A larger one
  is split into time buckets (`time_bucket`), and each bucket contributes its
  first, last, lowest and highest reading. These are real readings at their
  real timestamps, so spikes and the overall shape survive, and a line drawn
  through them looks like the line through all readings. Zooming in asks for
  a smaller window, which gets narrower buckets and finally every reading.
  """

  alias SecantService.Repo
  alias SecantService.SecNodes.Parameter
  alias SecantService.SecNodes.ParameterValue

  @numeric_types ["double", "int", "scaled"]

  # a window with at most this many readings is returned in full
  @default_max_raw 3000
  # otherwise it is split into at most this many buckets (4 readings each)
  @default_max_buckets 400

  # bucket widths to pick from, in milliseconds; wider ones are whole days
  @second 1_000
  @minute 60 * @second
  @hour 60 * @minute
  @day 24 * @hour
  @bucket_widths [1, 2, 5, 10, 20, 50, 100, 200, 500] ++
                   Enum.map([1, 2, 5, 10, 15, 30], &(&1 * @second)) ++
                   Enum.map([1, 2, 5, 10, 15, 30], &(&1 * @minute)) ++
                   Enum.map([1, 2, 3, 6, 12], &(&1 * @hour))

  @type window :: %{
          values: [number],
          timestamps: [integer],
          aggregated: boolean,
          bucket_ms: pos_integer | nil
        }

  @doc "Whether a parameter's readings can be thinned out: plain numbers only."
  def numeric?(%Parameter{datainfo: %{"type" => type}}) when type in @numeric_types, do: true
  def numeric?(_), do: false

  @doc """
  Readings of `param` between `from_ms` and `to_ms` (Unix milliseconds, both
  inclusive; `nil` means from the first / to the last reading).

  Options: `:max_raw` and `:max_buckets`, see the module doc.
  """
  @spec window(Parameter.t(), integer | nil, integer | nil, keyword) :: window
  def window(%Parameter{} = param, from_ms, to_ms, opts \\ []) do
    table = table(param)

    case plan(param, from_ms, to_ms, opts) do
      :empty -> empty()
      {:raw, from, to} -> raw(table, param.id, from, to)
      {:buckets, from, to, bucket_ms} -> bucketed(table, param.id, from, to, bucket_ms)
    end
  end

  @doc """
  How `window/4` would answer, without loading the readings:
  `%{aggregated: boolean, bucket_ms: pos_integer | nil}`.
  """
  def resolution(%Parameter{} = param, from_ms, to_ms, opts \\ []) do
    case plan(param, from_ms, to_ms, opts) do
      {:buckets, _from, _to, bucket_ms} -> %{aggregated: true, bucket_ms: bucket_ms}
      _ -> %{aggregated: false, bucket_ms: nil}
    end
  end

  @doc """
  One resolution for a plot of several parameters: aggregated if any of them
  is, with the widest bucket.
  """
  def coarsest(resolutions) do
    case resolutions |> Enum.filter(& &1.aggregated) |> Enum.map(& &1.bucket_ms) do
      [] -> %{aggregated: false, bucket_ms: nil}
      widths -> %{aggregated: true, bucket_ms: Enum.max(widths)}
    end
  end

  defp plan(param, from_ms, to_ms, opts) do
    max_raw = Keyword.get(opts, :max_raw, @default_max_raw)
    max_buckets = Keyword.get(opts, :max_buckets, @default_max_buckets)
    table = table(param)

    case bounds(table, param.id, from_ms, to_ms) do
      nil ->
        :empty

      {from, to} ->
        if count_up_to(table, param.id, from, to, max_raw + 1) > max_raw do
          span_ms = NaiveDateTime.diff(to, from, :millisecond)
          {:buckets, from, to, bucket_width(span_ms, max_buckets)}
        else
          {:raw, from, to}
        end
    end
  end

  @doc """
  The narrowest bucket width (ms) from a fixed list of round widths that
  covers `span_ms` with at most `max_buckets` buckets.
  """
  def bucket_width(span_ms, max_buckets) do
    needed = max(span_ms, 1) / max_buckets

    Enum.find(@bucket_widths, &(&1 >= needed)) || ceil(needed / @day) * @day
  end

  defp empty, do: %{values: [], timestamps: [], aggregated: false, bucket_ms: nil}

  # value tables are fixed names taken from the Ash resources, never user input
  defp table(param) do
    param |> ParameterValue.get_resource_module() |> AshPostgres.DataLayer.Info.table()
  end

  # The requested window, with open ends replaced by the parameter's first and
  # last reading. nil when the parameter has no readings.
  defp bounds(_table, _id, from_ms, to_ms) when is_number(from_ms) and is_number(to_ms) do
    {to_naive(from_ms), to_naive(to_ms)}
  end

  defp bounds(table, id, from_ms, to_ms) do
    %{rows: [[first, last]]} =
      Repo.query!(
        ~s|SELECT min("timestamp"), max("timestamp") FROM #{table} WHERE parameter_id = $1|,
        [id]
      )

    if first do
      {(from_ms && to_naive(from_ms)) || first, (to_ms && to_naive(to_ms)) || last}
    end
  end

  defp to_naive(ms) do
    ms |> trunc() |> DateTime.from_unix!(:millisecond) |> DateTime.to_naive()
  end

  # number of readings in the window, counting no further than `limit`
  defp count_up_to(table, id, from, to, limit) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM (
          SELECT 1 FROM #{table}
          WHERE parameter_id = $1 AND "timestamp" >= $2 AND "timestamp" <= $3
          LIMIT $4
        ) readings
        """,
        [id, from, to, limit]
      )

    count
  end

  defp raw(table, id, from, to) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT "timestamp", value FROM #{table}
        WHERE parameter_id = $1 AND "timestamp" >= $2 AND "timestamp" <= $3
        ORDER BY "timestamp"
        """,
        [id, from, to]
      )

    {timestamps, values} = rows |> Enum.map(&point/1) |> Enum.unzip()
    %{values: values, timestamps: timestamps, aggregated: false, bucket_ms: nil}
  end

  # Per bucket: the first and last reading, and the readings with the lowest
  # and highest value. `first(a, b)` is TimescaleDB's "a of the row with the
  # smallest b", so `first("timestamp", value)` is when the minimum occurred.
  defp bucketed(table, id, from, to, bucket_ms) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT
          min("timestamp"), first(value, "timestamp"),
          first("timestamp", value), min(value),
          last("timestamp", value), max(value),
          max("timestamp"), last(value, "timestamp")
        FROM #{table}
        WHERE parameter_id = $1 AND "timestamp" >= $2 AND "timestamp" <= $3
        GROUP BY time_bucket($4::interval, "timestamp")
        ORDER BY 1
        """,
        [id, from, to, %Postgrex.Interval{microsecs: bucket_ms * 1000}]
      )

    {timestamps, values} =
      rows
      |> Enum.flat_map(fn row ->
        row
        |> Enum.chunk_every(2)
        |> Enum.map(&point/1)
        # a bucket's first/last reading is often also its lowest/highest
        |> Enum.uniq_by(&elem(&1, 0))
        |> Enum.sort_by(&elem(&1, 0))
      end)
      |> Enum.unzip()

    %{values: values, timestamps: timestamps, aggregated: true, bucket_ms: bucket_ms}
  end

  defp point([%NaiveDateTime{} = ts, value]) do
    ms = ts |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)
    {ms, number(value)}
  end

  # NaN and infinities can't be plotted
  defp number(%Decimal{coef: coef}) when coef in [:NaN, :inf], do: nil
  defp number(%Decimal{} = value), do: Decimal.to_float(value)
  defp number(value), do: value
end
