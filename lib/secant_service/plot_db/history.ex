defmodule SecantService.PlotDB.History do
  @moduledoc """
  Readings of a parameter for the historical plots, thinned out in the
  database when a time window holds more than a chart can show. Works for
  every type the plots draw: numbers, enums, numeric arrays and structs.

  A window with up to `max_raw` readings is returned as stored. A larger one
  is split into time buckets (`time_bucket`), and each bucket keeps a few of
  its readings: its first and last, plus what each of the parameter's
  channels picks (see `SecantService.PlotDB.History.Channels`), such as the
  readings with the lowest and highest value of every array element, or the
  first reading of each enum state. The kept readings are returned whole, as
  stored, so every plot draws them like any other readings. Zooming in asks
  for a smaller window, which gets narrower buckets and finally every reading.

  For arrays and structs, ties (several readings with the same lowest value,
  say) go to the earliest reading, so a window always comes back the same,
  however the rows are stored (compressed chunks are scanned in another
  order).

  A plain number or enum in its own column is thinned in one aggregate pass
  that returns the kept values directly. Arrays and structs pick reading ids
  in a CTE and fetch those readings in the same statement.

  The limits follow from a budget of values per chart (`@point_budget`): a
  reading of a 50-element array costs 50 values, so its window gets fewer
  readings and buckets than a plain number's.
  """

  import Ecto.Query

  alias SecantService.PlotDB.History.Channels
  alias SecantService.Repo
  alias SecantService.SecNodes.Parameter
  alias SecantService.SecNodes.Reading.Storage

  # values (readings × values per reading) a chart is sent at most
  @point_budget 200_000
  # a window with at most this many readings is returned in full ...
  @default_max_raw 3000
  # ... otherwise it is split into at most this many buckets
  @default_max_buckets 400
  # wide structs and arrays still get this many
  @min_buckets 50

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
          values: [term],
          timestamps: [integer],
          aggregated: boolean,
          bucket_ms: pos_integer | nil
        }

  @doc "Whether a parameter's readings can be thinned out: anything the plots draw."
  def thinnable?(%Parameter{datainfo: datainfo}), do: Channels.from_datainfo(datainfo) != []
  def thinnable?(_), do: false

  @doc """
  Readings of `param` between `from_ms` and `to_ms` (Unix milliseconds, both
  inclusive; `nil` means from the first / to the last reading).

  Options: `:max_raw` and `:max_buckets`, see the module doc. Without them,
  both follow from the parameter's type (see `limits/1`).
  """
  @spec window(Parameter.t(), integer | nil, integer | nil, keyword) :: window
  def window(%Parameter{} = param, from_ms, to_ms, opts \\ []) do
    col = column(param)

    case plan(param, from_ms, to_ms, opts) do
      :empty -> empty()
      {:raw, from, to} -> raw(col, param.id, from, to)
      {:buckets, from, to, bucket_ms} -> bucketed(param, col, from, to, bucket_ms)
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

  @doc """
  `{max_raw, max_buckets}` for a parameter: as many readings and buckets as
  fit the value budget, never more than for a plain number.
  """
  def limits(%Parameter{datainfo: datainfo}) do
    channels = Channels.from_datainfo(datainfo)
    points = Channels.points_per_reading(channels)
    per_bucket = points * Channels.picks_per_bucket(channels)

    {min(@default_max_raw, max(div(@point_budget, points), @min_buckets)),
     @point_budget |> div(per_bucket) |> max(@min_buckets) |> min(@default_max_buckets)}
  end

  defp plan(param, from_ms, to_ms, opts) do
    {default_raw, default_buckets} = limits(param)
    max_raw = Keyword.get(opts, :max_raw, default_raw)
    max_buckets = Keyword.get(opts, :max_buckets, default_buckets)
    col = column(param)

    case bounds(col, param.id, from_ms, to_ms) do
      nil ->
        :empty

      {from, to} ->
        if count_up_to(col, param.id, from, to, max_raw + 1) > max_raw do
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

  # the parameter's value column; readings kept in another column (a value
  # that did not fit the declared type) are not plotted
  defp column(param), do: Storage.column(param)

  # The requested window, with open ends replaced by the parameter's first and
  # last reading. nil when the parameter has no readings.
  defp bounds(_col, _id, from_ms, to_ms) when is_number(from_ms) and is_number(to_ms) do
    {to_naive(from_ms), to_naive(to_ms)}
  end

  defp bounds(col, id, from_ms, to_ms) do
    {first, last} =
      Repo.one(
        from v in "readings",
          where: v.parameter_id == ^id and not is_nil(field(v, ^col)),
          select: {min(v.timestamp), max(v.timestamp)}
      )

    if first do
      {(from_ms && to_naive(from_ms)) || first, (to_ms && to_naive(to_ms)) || last}
    end
  end

  defp to_naive(ms) do
    ms |> trunc() |> DateTime.from_unix!(:millisecond) |> DateTime.to_naive()
  end

  defp readings(col, id, from, to) do
    from v in "readings",
      where:
        v.parameter_id == ^id and v.timestamp >= ^from and v.timestamp <= ^to and
          not is_nil(field(v, ^col))
  end

  # number of readings in the window, counting no further than `limit`
  defp count_up_to(col, id, from, to, limit) do
    capped = from v in readings(col, id, from, to), limit: ^limit, select: %{one: 1}

    Repo.one(from r in subquery(capped), select: count())
  end

  defp raw(col, id, from, to) do
    from(v in readings(col, id, from, to),
      order_by: v.timestamp,
      select: [v.timestamp, field(v, ^col)]
    )
    |> Repo.all()
    |> to_window(col, false, nil)
  end

  # -- thinning ------------------------------------------------------------------

  # Three ways to thin a window, cheapest first. A plain number or enum in
  # its own column gets its kept values straight from one aggregate pass, as
  # the readings are short; arrays and structs pick reading ids, then fetch
  # those readings whole.
  defp bucketed(param, col, from, to, bucket_ms) do
    width = %Postgrex.Interval{microsecs: bucket_ms * 1000}

    case Channels.from_datainfo(param.datainfo) do
      [%Channels{source: {:column, _}, kind: :number, picker: :extremes}] ->
        number_buckets(col, param.id, from, to, width)

      [%Channels{source: {:column, _}, kind: :state, picker: :each_state}] ->
        state_buckets(col, param.id, from, to, width)

      channels ->
        picked_readings(channels, col, param.id, from, to, width)
    end
    |> to_window(col, true, bucket_ms)
  end

  # Per bucket the first, last, lowest and highest reading, as `[ts, value]`
  # rows. TimescaleDB's `first(a, b)` is "a of the row with the smallest b".
  # Ties between equal values go to whichever reading the scan meets first,
  # which does not change the drawn line.
  defp number_buckets(col, id, from, to, width) do
    from(v in readings(col, id, from, to),
      group_by: fragment("time_bucket(?::interval, ?)", ^width, v.timestamp),
      select: [
        min(v.timestamp),
        fragment("first(?, ?)", field(v, ^col), v.timestamp),
        fragment("first(?, ?)", v.timestamp, field(v, ^col)),
        min(field(v, ^col)),
        fragment("last(?, ?)", v.timestamp, field(v, ^col)),
        max(field(v, ^col)),
        max(v.timestamp),
        fragment("last(?, ?)", field(v, ^col), v.timestamp)
      ]
    )
    |> Repo.all()
    |> Enum.flat_map(&Enum.chunk_every(&1, 2))
    |> sorted_unique()
  end

  # Per bucket the first reading of each state and the bucket's last reading,
  # as `[ts, value]` rows, from one pass grouped by bucket and state: the
  # state whose last reading is the bucket's latest held at its end.
  defp state_buckets(col, id, from, to, width) do
    rows =
      from v in readings(col, id, from, to),
        select: %{
          b: fragment("time_bucket(?::interval, ?)", ^width, v.timestamp),
          v: field(v, ^col),
          ts: v.timestamp
        }

    groups =
      from r in subquery(rows),
        group_by: [r.b, r.v],
        select: %{b: r.b, v: r.v, t0: min(r.ts), t1: max(r.ts)}

    from(g in subquery(groups),
      select: [
        g.t0,
        g.v,
        g.t1,
        g.v,
        fragment("? = max(?) OVER (PARTITION BY ?)", g.t1, g.t1, g.b)
      ]
    )
    |> Repo.all()
    |> Enum.flat_map(fn [t0, v, t1, v, last?] ->
      if last?, do: [[t0, v], [t1, v]], else: [[t0, v]]
    end)
    |> sorted_unique()
  end

  defp sorted_unique(points),
    do: points |> Enum.uniq_by(&hd/1) |> Enum.sort_by(&hd/1, NaiveDateTime)

  # Arrays and structs: each channel picks reading ids (see `bucket_ends/2`),
  # and the picked readings are then fetched whole. The ids go through a
  # materialized CTE into a hash semi-join: compressed chunks have no index
  # on id, so `id = ANY(array)` would compare every row of the window with
  # every pick.
  defp picked_readings(channels, col, id, from, to, width) do
    base = readings(col, id, from, to)

    picks =
      union_all_of([
        bucket_ends(base, width) | Enum.flat_map(channels, &channel_picks(base, width, &1))
      ])

    # the id is the last element of every pick key
    ids =
      from p in "picks",
        cross_lateral_join:
          k in fragment(
            "SELECT k FROM (VALUES (?), (?), (?), (?)) AS ks(k)",
            p.first,
            p.last,
            p.lo,
            p.hi
          ),
        where: not is_nil(k.k),
        distinct: true,
        select: %{id: fragment("(?)[array_upper(?, 1)]::bigint", k.k, k.k)}

    from(v in readings(col, id, from, to),
      where: v.id in subquery(from i in "ids", select: i.id),
      order_by: v.timestamp,
      select: [v.timestamp, field(v, ^col)]
    )
    |> with_cte("picks", as: ^picks)
    |> with_cte("ids", as: ^ids, materialized: true)
    |> Repo.all()
  end

  defp union_all_of([first | rest]), do: Enum.reduce(rest, first, &union_all(&2, ^&1))

  # Each pick query returns `%{first:, last:, lo:, hi:}`, keys of the
  # readings it picks in a group, or NULL. A key is `[seconds since epoch,
  # id]` to pick by time and `[value, seconds since epoch, id]` to pick by
  # value: the smallest and largest key of a group are its first and last
  # reading, or the ones with the lowest and highest value, ties going to
  # the earliest (latest) reading. Float8 arrays, unlike row values, can be
  # combined across parallel workers; they hold ids exactly (below 2^53) and
  # tell timestamps 1 µs apart. `date_part` keeps the seconds a float8;
  # `extract` would compute them as numeric, at twice the cost of the whole
  # query.

  # every bucket's first and last reading, so the time axis keeps its extent
  # and a held value (a state, a heatmap row) ends where it really ended
  defp bucket_ends(base, width) do
    from v in base,
      group_by: fragment("time_bucket(?::interval, ?)", ^width, v.timestamp),
      select: %{
        first: fragment("min(ARRAY[date_part('epoch', ?), ?::float8])", v.timestamp, v.id),
        last: fragment("max(ARRAY[date_part('epoch', ?), ?::float8])", v.timestamp, v.id),
        lo: fragment("NULL::float8[]"),
        hi: fragment("NULL::float8[]")
      }
  end

  defp channel_picks(_base, _width, %Channels{picker: :first_last}), do: []

  defp channel_picks(base, width, %Channels{picker: :extremes} = channel),
    do: [extremes(base, width, channel)]

  # the first reading of each value
  defp channel_picks(base, width, %Channels{picker: :each_state} = channel) do
    values = channel_values(base, width, channel)

    query =
      from c in subquery(values),
        where: not is_nil(c.v),
        group_by: c.v,
        select: %{
          first: fragment("min(ARRAY[?, ?::float8])", c.t, c.id),
          last: fragment("NULL::float8[]"),
          lo: fragment("NULL::float8[]"),
          hi: fragment("NULL::float8[]")
        }

    [group_per_element(query, channel)]
  end

  # the readings with the lowest and the highest value
  defp extremes(base, width, channel) do
    values = channel_values(base, width, channel)

    query =
      from c in subquery(values),
        where: not is_nil(c.v),
        select: %{
          first: fragment("NULL::float8[]"),
          last: fragment("NULL::float8[]"),
          lo: fragment("min(ARRAY[?, ?, ?::float8])", c.v, c.t, c.id),
          hi: fragment("max(ARRAY[?, ?, ?::float8])", c.v, c.t, c.id)
        }

    group_per_element(query, channel)
  end

  defp group_per_element(query, %Channels{per_element?: true}),
    do: group_by(query, [c], [c.b, c.i])

  defp group_per_element(query, _channel), do: group_by(query, [c], c.b)

  # One row per value of the channel: `%{id, t, b, i, v}` with the reading's
  # id and seconds since epoch, its bucket, the array index (0 for a single value) and
  # the value.
  defp channel_values(base, width, %Channels{kind: kind, source: source}) do
    query =
      from v in base,
        select: %{
          id: v.id,
          t: fragment("date_part('epoch', ?)", v.timestamp),
          b: fragment("time_bucket(?::interval, ?)", ^width, v.timestamp)
        }

    values(query, kind, source)
  end

  # Every value is a float8: enum states are integers, and the pick keys
  # are float8 arrays. A JSON number beyond float8's range (a node can send
  # any number) counts as no value instead of failing the whole query; the
  # nested CASE makes sure only numbers reach the casts.
  defp values(query, kind, {:column, col}) when kind in [:number, :state],
    do: select_merge(query, [v], %{i: 0, v: fragment("?::float8", field(v, ^col))})

  defp values(query, kind, {:json, path}) when kind in [:number, :state] do
    select_merge(query, [v], %{
      i: 0,
      v:
        fragment(
          """
          CASE WHEN jsonb_typeof(? #> ?) = 'number' THEN
            CASE WHEN abs((? #> ?)::numeric) = 0 OR abs((? #> ?)::numeric) BETWEEN 1e-300 AND 1e300
            THEN (? #> ?)::numeric::float8 END
          END
          """,
          v.value_json,
          type(^path, {:array, :string}),
          v.value_json,
          type(^path, {:array, :string}),
          v.value_json,
          type(^path, {:array, :string}),
          v.value_json,
          type(^path, {:array, :string})
        )
    })
  end

  defp values(query, :number_array, {:column, col}) do
    from v in query,
      cross_lateral_join:
        e in fragment(
          "SELECT x.v::float8 AS v, x.i FROM unnest(?) WITH ORDINALITY AS x(v, i)",
          field(v, ^col)
        ),
      select_merge: %{i: e.i, v: e.v}
  end

  defp values(query, :number_array, {:json, path}) do
    from v in query,
      cross_lateral_join:
        e in fragment(
          """
          SELECT CASE WHEN jsonb_typeof(x.e) = 'number' THEN
              CASE WHEN abs(x.e::numeric) = 0 OR abs(x.e::numeric) BETWEEN 1e-300 AND 1e300
              THEN x.e::numeric::float8 END
            END AS v, x.i
          FROM jsonb_array_elements(
            CASE WHEN jsonb_typeof(? #> ?) = 'array' THEN ? #> ? ELSE '[]'::jsonb END
          ) WITH ORDINALITY AS x(e, i)
          """,
          v.value_json,
          type(^path, {:array, :string}),
          v.value_json,
          type(^path, {:array, :string})
        ),
      select_merge: %{i: e.i, v: e.v}
  end

  # -- decoding --------------------------------------------------------------------

  defp to_window(rows, col, aggregated, bucket_ms) do
    {timestamps, values} =
      rows
      |> Enum.map(fn [ts, value] -> {to_ms(ts), decode(col, value)} end)
      |> Enum.unzip()

    %{values: values, timestamps: timestamps, aggregated: aggregated, bucket_ms: bucket_ms}
  end

  defp to_ms(%NaiveDateTime{} = ts),
    do: ts |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)

  # as `Storage.raw_value/1` reads a stored value back
  defp decode(:value_json, %{"type" => _, "json" => text}) when is_binary(text),
    do: Jason.decode!(text)

  defp decode(:value_json, %{"value" => value}), do: value
  defp decode(:value_json, value), do: value
  defp decode(_col, values) when is_list(values), do: Enum.map(values, &number/1)
  defp decode(_col, value), do: number(value)

  # NaN and infinities (Postgrex returns them as atoms) can't be plotted
  defp number(value) when is_number(value) or is_boolean(value), do: value
  defp number(_nan_or_infinity), do: nil
end
