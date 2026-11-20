defmodule SecantService.PlotDB.Builders do
  alias SecantService.PlotDB.History
  alias SecantService.SecNodes.ParameterValue
  alias SecantService.SecNodes.Parameter
  alias SecantClient.NodeStatem
  require Logger

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
      %{values: values, timestamps: timestamps} = Parameter.history_window!(param.id, nil, nil)
      {values, timestamps}
    else
      get_values(param) |> ParameterValue.extract_value_timestamp_lists(param)
    end
    |> read_from_device_if_empty(param.id)
  end

  def fetch_param_data(param, :live) do
    {from_ms, to_ms, _buttons, _active} = default_live_range_ms()
    windowed = fetch_param_data_in_range(param, from_ms, to_ms)

    case windowed do
      {[], []} ->
        if any_data?(param), do: windowed, else: read_from_device_if_empty(windowed, param.id)

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

    ParameterValue.get_resource_module(param)
    |> Ash.Query.for_read(:for_parameter, %{
      parameter_id: param.id,
      end_timestamp: end_ts,
      limit: 1,
      order: :desc
    })
    |> Ash.read!()
    |> ParameterValue.extract_value_timestamp_lists(param)
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
    case ParameterValue.get_resource_module(param)
         |> Ash.Query.for_read(:for_parameter, %{parameter_id: param.id, limit: 1, order: :desc})
         |> Ash.read_first() do
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
      %{parameter_id: param.id}
      |> maybe_put(:start_timestamp, from_ms && DateTime.from_unix!(trunc(from_ms), :millisecond))
      |> maybe_put(:end_timestamp, to_ms && DateTime.from_unix!(trunc(to_ms), :millisecond))

    ParameterValue.get_resource_module(param)
    |> Ash.Query.for_read(:for_parameter, args)
    |> Ash.read!()
    |> ParameterValue.extract_value_timestamp_lists(param)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp get_values(parameter) do
    ParameterValue.get_resource_module(parameter)
    |> Ash.Query.for_read(:for_parameter, %{parameter_id: parameter.id})
    |> Ash.read!()
  end

  defp read_from_device_if_empty({_value_val, _value_ts} = readings, param_id) do
    case readings do
      {[], []} ->
        Logger.warning(
          "No values found in DB for param_id: #{param_id}, trying to read from device"
        )

        parameter =
          Parameter
          |> Ash.Query.for_read(:get_with_context, %{id: param_id})
          |> Ash.read_first!()

        read_until_valid(
          parameter.module.sec_node.node_id,
          parameter.module.name,
          parameter.name
        )

      {_, _} ->
        readings
    end
  end

  defp read_until_valid(id, module_name, parameter_name) do
    case NodeStatem.read(id, module_name, parameter_name) do
      {:reply, _r_mod, _r_para, [val, %{t: ts}]} ->
        val = val |> Jason.encode!() |> Jason.decode!()

        secs = trunc(ts)
        usecs = trunc((ts - secs) * 1_000_000)
        {:ok, dt} = DateTime.from_unix(secs)
        ts = %{dt | microsecond: {usecs, 6}} |> DateTime.to_unix(:millisecond)

        {[val], [ts]}

      {:error, :read, _specifier, _error_class, error_text, _error_dict} ->
        Logger.warning("Read failed: #{error_text}, retrying...")
        Process.sleep(10_000)
        read_until_valid(id, module_name, parameter_name)

      other ->
        Logger.warning("Unexpected response: #{inspect(other)}, retrying...")
        Process.sleep(20_000)
        read_until_valid(id, module_name, parameter_name)
    end
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
