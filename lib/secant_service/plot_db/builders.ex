defmodule SecantService.PlotDB.Builders do
  alias SecantService.SecNodes.ParameterValue
  alias SecantService.SecNodes.Parameter
  alias SEC_Node_Statem
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

  def fetch_param_data(param, :historical) do
    get_values(param)
    |> ParameterValue.extract_value_timestamp_lists(param)
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
  # Values are only stored when they change, so a single stored value is a
  # complete history (the value has not changed since).
  def plot_available?(vals, _param, :historical), do: vals != []
  def plot_available?(vals, param, :live), do: vals != [] or any_data?(param)

  @doc """
  Values and timestamps (ms) of `param` within `[from_ms, to_ms]`.

  Values are stored only when they change (plus a periodic heartbeat), so the
  value in effect at `from_ms` may have been written long before it. When
  `from_ms` is given, the last value before the window is included as an
  anchor point at `from_ms`.
  """
  def fetch_param_data_in_range(param, from_ms, to_ms) do
    from_dt = from_ms && DateTime.from_unix!(trunc(from_ms), :millisecond)

    args =
      %{parameter_id: param.id}
      |> maybe_put(:start_timestamp, from_dt)
      |> maybe_put(:end_timestamp, to_ms && DateTime.from_unix!(trunc(to_ms), :millisecond))

    resource = ParameterValue.get_resource_module(param)

    in_window =
      resource
      |> Ash.Query.for_read(:for_parameter, args)
      |> Ash.read!()

    (anchor_before(resource, param, from_dt) ++ in_window)
    |> ParameterValue.extract_value_timestamp_lists(param)
  end

  defp anchor_before(_resource, _param, nil), do: []

  defp anchor_before(resource, param, from_dt) do
    resource
    |> Ash.Query.for_read(:for_parameter, %{
      parameter_id: param.id,
      # strictly before the window; rows at from_dt are already in it
      end_timestamp:
        DateTime.from_unix!(DateTime.to_unix(from_dt, :microsecond) - 1, :microsecond),
      order: :desc,
      limit: 1
    })
    |> Ash.read!()
    |> Enum.map(&%{&1 | timestamp: from_dt})
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
    case SEC_Node_Statem.read(id, module_name, parameter_name) do
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
