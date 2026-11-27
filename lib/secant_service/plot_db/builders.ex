defmodule SecantService.PlotDB.Builders do
  import Ecto.Query

  alias SecantService.Repo
  alias SecantService.SecNodes
  alias SecantService.PlotDB.History
  alias SecantService.SecNodes.Reading.Storage
  alias SecantService.NodeValues

  @unthinned %{aggregated: false, bucket_ms: nil}

  # ---------------------------------------------------------------------------
  # Parameter helpers
  # ---------------------------------------------------------------------------

  def find_param(module, name) do
    Enum.find(module.parameters, &(&1.name == name))
  end

  # ---------------------------------------------------------------------------
  # Data fetching
  # ---------------------------------------------------------------------------

  @doc """
  Like `fetch_param_window/2`, without the resolution.
  """
  def fetch_param_data(param, mode) do
    {values, timestamps, _resolution} = fetch_param_window(param, mode)
    {values, timestamps}
  end

  @doc """
  The readings a plot of `param` starts with, as `{values, timestamps,
  resolution}`. The resolution says whether they were thinned out (see
  `History.resolution/4`); a plot passes it on with `put_resolution/2`, so
  the chart need not ask the database again.

  Historical: the whole recording from the session start on, thinned out in
  the database (see `History`) for every type the plots draw. The chart asks
  for more detail when it is zoomed in.

  Readings carry the node's timestamp, which for a parameter that has not
  changed in a while (a setpoint, a configuration value) is the time of its
  last change, often days before the recording began. Such a reading would
  stretch the time axis back to then and squeeze the recording against its
  right edge, so it is pinned to where the plot starts instead (see
  `plot_start_ms/1`).
  """
  def fetch_param_window(param, mode, opts \\ [])

  def fetch_param_window(param, :historical, opts) do
    from_ms = plot_start_ms(param)
    args = if Keyword.get(opts, :envelope, false), do: %{envelope: true}, else: %{}

    {values, timestamps, resolution} =
      if History.thinnable?(param) do
        window = SecNodes.history_window!(param.id, from_ms, nil, args)

        {window.values, window.timestamps, Map.take(window, [:aggregated, :bucket_ms, :envelope])}
      else
        {values, timestamps} = fetch_param_data_in_range(param, from_ms, nil)
        {values, timestamps, @unthinned}
      end

    {values, timestamps} = hold_from(param, from_ms, values, timestamps)
    {values, timestamps, resolution}
  end

  def fetch_param_window(param, :live, _opts) do
    {values, timestamps} = fetch_live_data(param)
    {values, timestamps, @unthinned}
  end

  @doc """
  Puts the resolution of the readings a historical plot was built from on
  its chart (`_windowFetch`, see `history_zoom/2`): thinned out if any of
  them is, with the widest bucket. Other plots are returned as they are.
  """
  def put_resolution(%{option: %{_windowFetch: _}} = plot, resolutions) do
    resolution =
      case resolutions |> Enum.map(&envelope_bucket_ms/1) |> Enum.reject(&is_nil/1) do
        [] -> History.coarsest(resolutions)
        widths -> Map.put(History.coarsest(resolutions), :envelope_bucket_ms, Enum.max(widths))
      end

    put_in(plot, [:option, :_windowFetch], resolution)
  end

  def put_resolution(plot, _resolutions), do: plot

  defp envelope_bucket_ms(%{envelope: %{bucket_ms: bucket_ms}}), do: bucket_ms
  defp envelope_bucket_ms(_resolution), do: nil

  @doc "`put_resolution/2` on a `PlotSpec.plot/2` result."
  def with_resolution({:ok, plot}, resolutions), do: {:ok, put_resolution(plot, resolutions)}
  def with_resolution(result, _resolutions), do: result

  @doc "`SecantService.PlotDB.put_envelopes/4` on a `PlotSpec.plot/2` result."
  def with_envelopes({:ok, plot}, secop_obj, mode, envelopes),
    do: {:ok, SecantService.PlotDB.put_envelopes(plot, secop_obj, mode, envelopes)}

  def with_envelopes(result, _secop_obj, _mode, _envelopes), do: result

  defp fetch_live_data(param) do
    {from_ms, to_ms, _buttons, _active} = default_live_range_ms()
    windowed = fetch_param_data_in_range(param, from_ms, to_ms)

    case windowed do
      {[], []} ->
        if any_data?(param), do: windowed, else: current_value(param)

      _ ->
        windowed
    end
  end

  @doc """
  Like `fetch_param_window/2`, for a setpoint (`target`). A setpoint is only
  recorded when it changes, so a live window often holds no reading of it at
  all. The last reading before the window is added, pinned to the window
  start, so the plot shows the setpoint in force since then.
  """
  def fetch_held_param_window(param, :live) do
    {from_ms, _to_ms, _buttons, _active} = default_live_range_ms()
    {values, timestamps} = fetch_live_data(param)
    {values, timestamps} = hold_from(param, from_ms, values, timestamps)
    {values, timestamps, @unthinned}
  end

  def fetch_held_param_window(param, mode), do: fetch_param_window(param, mode)

  @doc """
  Puts the last reading before `from_ms` in front of `values`/`timestamps`,
  at `from_ms`. Unchanged when there is no window start or earlier reading.
  """
  def hold_from(_param, nil, values, timestamps), do: {values, timestamps}

  def hold_from(param, from_ms, values, timestamps) do
    case last_before(param, from_ms) do
      nil -> {values, timestamps}
      value -> {[value | values], [trunc(from_ms) | timestamps]}
    end
  end

  defp last_before(param, from_ms) do
    end_ts = DateTime.from_unix!(trunc(from_ms) - 1, :millisecond)

    param.id
    |> SecNodes.latest_reading!(%{end_timestamp: end_ts})
    |> List.wrap()
    |> Storage.value_timestamp_lists()
    |> case do
      {[value | _], _} -> value
      _ -> nil
    end
  end

  @doc """
  True if a parameter has at least one stored value, regardless of time range.
  Used to distinguish "empty because the live window has no recent data" from
  "empty because nothing has ever been recorded" without re-fetching full history.
  """
  def any_data?(param) do
    case SecNodes.latest_reading(param.id) do
      {:ok, nil} -> false
      {:ok, _record} -> true
      # Transient DB error: assume data exists rather than trigger a spurious device read.
      {:error, _} -> true
    end
  end

  @doc """
  Whether a plot has enough data to render. For :live plots, data just outside
  the visible window still counts — only truly parameter-less plots are excluded.
  """
  def plot_available?(vals, _param, :historical), do: length(vals) > 1
  def plot_available?(vals, param, :live), do: length(vals) > 1 or any_data?(param)

  def fetch_param_data_in_range(param, from_ms, to_ms) do
    args =
      %{}
      |> maybe_put(:start_timestamp, from_ms && DateTime.from_unix!(trunc(from_ms), :millisecond))
      |> maybe_put(:end_timestamp, to_ms && DateTime.from_unix!(trunc(to_ms), :millisecond))

    param.id
    |> SecNodes.readings!(args)
    |> Storage.value_timestamp_lists()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Where the historical plot of `param` begins (Unix milliseconds): when its
  session started.

  Only a parameter's first reading can carry a stale timestamp (the node's
  time of its last change, sent on activation). If its second reading also
  lies before the session start, the node's clock runs behind the server's,
  and the plot begins at that reading instead, so no recorded data is hidden.
  """
  def plot_start_ms(param) do
    %{session_started_at: started} = Ash.load!(param, :session_started_at)
    started_ms = DateTime.to_unix(started, :millisecond)

    case second_reading_ms(param) do
      ms when is_integer(ms) and ms < started_ms -> ms
      _ -> started_ms
    end
  end

  # the second distinct timestamp: a reading may be stored twice
  defp second_reading_ms(param) do
    first =
      from r in "readings", where: r.parameter_id == ^param.id, select: min(r.timestamp)

    query =
      from r in "readings",
        where: r.parameter_id == ^param.id and r.timestamp > subquery(first),
        order_by: r.timestamp,
        limit: 1,
        select: r.timestamp

    case Repo.one(query) do
      nil -> nil
      ts -> ts |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)
    end
  end

  # Nothing recorded yet for a live plot: start from the value the node
  # services already hold. Never reads from the device.
  defp current_value(param) do
    parameter = SecNodes.get_parameter!(param.id)

    case NodeValues.get_value(
           parameter.module.sec_node.node_id,
           parameter.module.name,
           parameter.name
         ) do
      {:ok, %{data_report: [value, %{t: ts}]}} when is_number(ts) ->
        {[stringify_keys(value)], [round(ts * 1000)]}

      _ ->
        {[], []}
    end
  end

  # Values from the node services carry atom keys; stored readings do not.
  defp stringify_keys(%{} = map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  @doc """
  Zoom for a historical plot: mouse-wheel / drag zoom on its time axes, a
  box-zoom tool and a reset. `_windowFetch` makes the chart ask for the
  readings of the window it is zoomed to (see `History`); the plot replaces
  it with the resolution of its first load (`put_resolution/2`).

  Options: `x_axes:` the number of time axes zoomed together (the grids of a
  struct plot), `toolbox_right:` where the tools sit, in pixels from the
  right edge, and `keep_outside: true` for plots whose readings hold until
  the next one (heatmaps, enum bands): ECharts then keeps the readings
  outside the zoomed window, so the one before it still reaches into it.
  """
  def history_zoom(option, opts \\ []) do
    axes =
      case Keyword.get(opts, :x_axes, 1) do
        1 -> 0
        n -> Enum.to_list(0..(n - 1))
      end

    filter = if Keyword.get(opts, :keep_outside, false), do: "none", else: "filter"

    option
    |> Map.put(:_windowFetch, %{aggregated: false, bucket_ms: nil})
    |> Map.put(:dataZoom, [%{type: "inside", xAxisIndex: axes, filterMode: filter}])
    |> Map.put(:toolbox, %{
      right: Keyword.get(opts, :toolbox_right, 8),
      top: 0,
      feature: %{
        dataZoom: %{xAxisIndex: axes, yAxisIndex: "none", filterMode: filter},
        restore: %{}
      }
    })
  end

  # ---------------------------------------------------------------------------
  # Range helpers — shared by all dtype option assemblers
  # ---------------------------------------------------------------------------

  @default_range_buttons [
    %{label: "1m", step: "minute", count: 1},
    %{label: "10m", step: "minute", count: 10},
    %{label: "30m", step: "minute", count: 30},
    %{label: "1h", step: "hour", count: 1},
    %{label: "1d", step: "day", count: 1},
    %{label: "all", step: "all"}
  ]
  @default_active_range_index 1

  def range_buttons do
    plot_db_config() |> Keyword.get(:range_buttons, @default_range_buttons)
  end

  def default_active_range_index do
    plot_db_config() |> Keyword.get(:default_active_range_index, @default_active_range_index)
  end

  defp plot_db_config, do: Application.get_env(:secant_service, :plot_db, [])

  @doc """
  Resolve the configured default range button against the current time.
  Shared by the mode-aware fetch above and the dtype option builders' initial
  x-axis window, so they can never disagree. If the configured default points
  at the "all" button, `compute_range/2` yields {nil, nil} and callers that
  fetch data will fall back to an unbounded fetch — that mirrors :historical
  behavior and is intentional.
  """
  def default_live_range_ms do
    buttons = range_buttons()
    active = default_active_range_index()
    now_ms = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    {x_min, x_max} = compute_range(Enum.at(buttons, active), now_ms)
    {x_min, x_max, buttons, active}
  end

  def compute_range(%{step: "all"}, _now_ms), do: {nil, nil}

  def compute_range(%{step: step, count: count}, now_ms) do
    ms =
      case step do
        "minute" -> count * 60 * 1_000
        "hour" -> count * 3_600 * 1_000
        "day" -> count * 86_400 * 1_000
        _ -> 0
      end

    {now_ms - ms, now_ms}
  end
end
