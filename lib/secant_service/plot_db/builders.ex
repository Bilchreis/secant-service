defmodule SecantService.PlotDB.Builders do
  alias SecantService.SecNodes
  alias SecantService.PlotDB.History
  alias SecantService.SecNodes.Reading.Storage
  alias SecantService.NodeValues

  # ---------------------------------------------------------------------------
  # Parameter helpers
  # ---------------------------------------------------------------------------

  def find_param(module, name) do
    Enum.find(module.parameters, &(&1.name == name))
  end

  # ---------------------------------------------------------------------------
  # Data fetching
  # ---------------------------------------------------------------------------

  # Numeric parameters: the whole recording, thinned out in the database
  # (see `History`). The chart asks for more detail when it is zoomed in.
  def fetch_param_data(param, :historical) do
    if History.numeric?(param) do
      %{values: values, timestamps: timestamps} = SecNodes.history_window!(param.id, nil, nil)
      {values, timestamps}
    else
      get_values(param) |> Storage.value_timestamp_lists()
    end
  end

  def fetch_param_data(param, :live) do
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
  Like `fetch_param_data/2`, for a setpoint (`target`). A setpoint is only
  recorded when it changes, so a live window often holds no reading of it at
  all. The last reading before the window is added, pinned to the window
  start, so the plot shows the setpoint in force since then.
  """
  def fetch_held_param_data(param, :live) do
    {from_ms, _to_ms, _buttons, _active} = default_live_range_ms()
    {values, timestamps} = fetch_param_data(param, :live)
    hold_from(param, from_ms, values, timestamps)
  end

  def fetch_held_param_data(param, mode), do: fetch_param_data(param, mode)

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

    param
    |> SecNodes.readings!(%{end_timestamp: end_ts, limit: 1, order: :desc})
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
    case SecNodes.latest_reading(param) do
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

    param
    |> SecNodes.readings!(args)
    |> Storage.value_timestamp_lists()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp get_values(parameter), do: SecNodes.readings!(parameter)

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
