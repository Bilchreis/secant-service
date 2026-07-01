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

  def fetch_param_data(param) do
    get_values(param)
    |> ParameterValue.extract_value_timestamp_lists(param)
    |> read_from_device_if_empty(param.id)
  end

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

  def range_buttons do
    [
      %{label: "1m", step: "minute", count: 1},
      %{label: "10m", step: "minute", count: 10},
      %{label: "30m", step: "minute", count: 30},
      %{label: "1h", step: "hour", count: 1},
      %{label: "1d", step: "day", count: 1},
      %{label: "all", step: "all"}
    ]
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
