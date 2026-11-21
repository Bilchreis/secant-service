defmodule SecantService.NodeValues do
  @moduledoc """
  The current value of every parameter of one node, processed for display.

  Changed values are not broadcast one by one. They are collected, latest per
  parameter, and published together every 250 ms as
  `{:value_updates, %{{module, parameter} => processed}}` on
  `SecantService.Topics.processed_values/1`. Every dashboard viewer of the
  node then handles a few messages per second instead of one per update.
  """
  use GenServer
  alias SecantClient.NodeTable
  alias SecantService.Topics
  require Logger

  @pubsub_name :secant_client_pubsub
  @default_publish_interval 250

  def start_link(node_db) do
    state = %{node_db: node_db}

    GenServer.start_link(__MODULE__, state,
      name: {:via, Registry, {Registry.NodeValues, node_db.node_id}}
    )
  end

  def get_values(node_id), do: call(node_id, :get_values)

  def get_node_db(node_id), do: call(node_id, :get_node_db)

  @doc """
  Returns `{:ok, {node_db, values}}` read atomically from the same process, so the
  description and the values always belong to the same node services generation.
  """
  def get_snapshot(node_id), do: call(node_id, :get_snapshot)

  def get_value(node_id, module, parameter) do
    case get_values(node_id) do
      {:ok, values} ->
        case get_in(values, [module, parameter]) do
          nil -> {:error, :not_found}
          value -> {:ok, value}
        end

      error ->
        error
    end
  end

  # The services of a node are stopped and restarted whenever its description
  # changes, so the process may vanish between the lookup and the call. Treat
  # that like "not running" instead of crashing the caller.
  defp call(node_id, message) do
    case Registry.lookup(Registry.NodeValues, node_id) do
      [] ->
        Logger.debug("NodeValues process not found for node ID: #{inspect(node_id)}")
        {:error, :not_found}

      [{pid, _value}] ->
        try do
          {:ok, GenServer.call(pid, message)}
        catch
          :exit, reason ->
            Logger.debug("NodeValues for #{inspect(node_id)} unavailable: #{inspect(reason)}")
            {:error, :not_found}
        end
    end
  end

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(@pubsub_name, Topics.value_update(state.node_db.node_id))
    Phoenix.PubSub.subscribe(@pubsub_name, Topics.error_update(state.node_db.node_id))

    # Remove any stale NodeTable entry before starting, so we always get a fresh table
    :ets.delete(:node_table_lookup, {:service, state.node_db.node_id})
    {:ok, table} = NodeTable.start({:service, state.node_db.node_id})

    values = get_val_map(state.node_db, table)

    state =
      state
      |> Map.put(:table, table)
      |> Map.put(:values, values)
      |> Map.put(:pending, %{})

    Logger.info(
      "Started NodeValues for Node: #{state.node_db.equipment_id} (#{state.node_db.uuid})"
    )

    {:ok, state}
  end

  @impl true
  def handle_info({:value_update, module, accessible, data_report}, state) do
    {:noreply, apply_update(state, module, accessible, data_report)}
  end

  def handle_info({:error_update, module, accessible, error_report}, state) do
    {:noreply, apply_update(state, module, accessible, {:error_report, error_report})}
  end

  def handle_info(:publish, state) do
    Phoenix.PubSub.broadcast(
      SecantService.PubSub,
      Topics.processed_values(state.node_db.node_id),
      {:value_updates, state.pending}
    )

    {:noreply, %{state | pending: %{}}}
  end

  defp apply_update(state, module, accessible, report) do
    case value_update(state.values, state.node_db, state.table, module, accessible, report) do
      {:ok, :updated, values, processed} ->
        if state.pending == %{}, do: Process.send_after(self(), :publish, publish_interval())
        pending = Map.put(state.pending, {module, accessible}, processed)
        %{state | values: values, pending: pending}

      _ ->
        state
    end
  end

  defp publish_interval,
    do: Application.get_env(:secant_service, :values_publish_interval, @default_publish_interval)

  @impl true
  def handle_call(:get_values, _from, state) do
    {:reply, state.values, state}
  end

  @impl true
  def handle_call(:get_node_db, _from, state) do
    {:reply, state.node_db, state}
  end

  def handle_call(:get_snapshot, _from, state) do
    {:reply, {state.node_db, state.values}, state}
  end

  def get_val_map(db_node, service_table) do
    node_id = db_node.node_id

    Enum.reduce(db_node.modules, %{}, fn module, mod_acc ->
      parameter_map =
        Enum.reduce(module.parameters, %{}, fn parameter, param_acc ->
          param_val =
            case NodeTable.lookup(
                   node_id,
                   {:data_report, String.to_existing_atom(module.name),
                    String.to_existing_atom(parameter.name)}
                 ) do
              {:ok, data_report} ->
                data_report

              {:error, _} ->
                Logger.warning(
                  "Data report for module #{module.name} and parameter #{parameter.name} not found in NodeTable for node #{db_node.host}:#{db_node.port}."
                )

                nil
            end

          param_val =
            process_data_report(parameter.name, param_val, parameter.datainfo)
            |> Map.put(:datainfo, parameter.datainfo)

          # write processed param val to service ets table
          insert_parameter_value(service_table, module.name, parameter.name, param_val)

          Map.put(param_acc, parameter.name, param_val)
        end)

      Map.put(mod_acc, module.name, parameter_map)
    end)
  end

  def insert_parameter_value(table, module, accessible, param_val) do
    # write param val to service ets table
    key = {:data_report, String.to_existing_atom(module), String.to_existing_atom(accessible)}
    value = param_val
    true = :ets.insert(table, {key, value})

    {:ok}
  end

  def value_update(values, _node_db, table, module, accessible, data_report) do
    # Check if the module exists

    case get_in(values, [module, accessible]) do
      nil ->
        Logger.warning("Parameter #{accessible} in module #{module} not found in values")
        {:error, :parameter_not_found, values}

      old_param_val ->
        new_param_val = process_data_report(accessible, data_report, old_param_val.datainfo)

        # Merge the old parameter value with the new one
        merged_param_val = Map.merge(old_param_val, new_param_val)

        # if incoming update is a data_report, remove any existing error_report
        merged_param_val =
          if Map.has_key?(new_param_val, :data_report) do
            Map.drop(merged_param_val, [:error_report])
          else
            merged_param_val
          end

        # Compare without timestamps
        old_without_timestamp = remove_timestamp(old_param_val)
        merged_without_timestamp = remove_timestamp(merged_param_val)

        if old_without_timestamp == merged_without_timestamp do
          {:ok, :equal, values}
        else
          insert_parameter_value(table, module, accessible, merged_param_val)

          {:ok, :updated, put_in(values, [module, accessible], merged_param_val), new_param_val}
        end
    end
  end

  # Remove timestamp from data_report qualifiers for comparison
  defp remove_timestamp(%{data_report: [value, qualifiers]} = param_val)
       when is_map(qualifiers) do
    Map.put(param_val, :data_report, [value, Map.drop(qualifiers, [:t])])
  end

  defp remove_timestamp(param_val), do: param_val

  # Error reports come first: they can arrive for any accessible, including
  # "status", whose clause below expects a [value, qualifiers] data report.
  def process_data_report(_accessible, {:error_report, [_cls, _msg | _] = report}, datainfo) do
    %{error_report: report, datainfo: datainfo}
  end

  def process_data_report("status", data_report, datainfo) do
    if data_report != nil do
      [value, _qualifiers] = data_report

      [stat_code, stat_string] = value

      %{
        data_report: data_report,
        stat_string: stat_string,
        stat_code: stat_code_lookup(stat_code, datainfo),
        stat_color: stat_code_to_color(stat_code),
        datainfo: datainfo
      }
    else
      %{
        data_report: nil,
        datainfo: datainfo
      }
    end
  end

  def process_data_report(nil, nil, nil) do
    nil
  end

  def process_data_report(_accessible, data_report, datainfo) do
    %{data_report: data_report, datainfo: datainfo}
  end

  def stat_code_lookup(stat_code, status_datainfo) do
    status_datainfo["members"]
    |> Enum.find(fn member -> member["type"] == "enum" end)
    |> case do
      %{"members" => members} ->
        members
        |> Enum.find(fn {_key, value} -> value == stat_code end)
        |> case do
          {key, _value} -> key
          nil -> :unknown
        end

      _ ->
        :unknown
    end
  end

  def stat_code_to_color(stat_code) do
    cond do
      # Disabled
      0 <= stat_code and stat_code < 100 -> :disabled
      # IDLE
      100 <= stat_code and stat_code < 200 -> :idle
      # WARNING
      200 <= stat_code and stat_code < 300 -> :warning
      # BUSY
      300 <= stat_code and stat_code < 400 -> :busy
      # ERROR
      400 <= stat_code and stat_code < 500 -> :error
      true -> :unknown
    end
  end
end
