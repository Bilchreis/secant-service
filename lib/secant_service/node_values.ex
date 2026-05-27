defmodule SecantService.NodeValues do
  use GenServer
  alias NodeTable
  require Logger

  @pubsub_name :secant_client_pubsub

  def start_link(node_db) do
    state = %{node_db: node_db}

    GenServer.start_link(__MODULE__, state,
      name: {:via, Registry, {Registry.NodeValues, node_db.node_id}}
    )
  end

  def get_values(node_id) do
    case Registry.lookup(Registry.NodeValues, node_id) do
      [] ->
        Logger.error("NodeValues process not found for node ID: #{inspect(node_id)}")
        {:error, :not_found}

      [{sec_node_pid, _value}] ->
        {:ok, GenServer.call(sec_node_pid, :get_values)}
    end
  end

  def get_node_db(node_id) do
    case Registry.lookup(Registry.NodeValues, node_id) do
      [] ->
        Logger.error("NodeValues process not found for node ID: #{inspect(node_id)}")
        {:error, :not_found}

      [{sec_node_pid, _value}] ->
        {:ok, GenServer.call(sec_node_pid, :get_node_db)}
    end
  end

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

  def get_table(node_id) do
    case Registry.lookup(Registry.NodeValues, node_id) do
      [] ->
        Logger.error("NodeValues process not found for node ID: #{inspect(node_id)}")
        {:error, :not_found}

      [{sec_node_pid, _value}] ->
        {:ok, GenServer.call(sec_node_pid, :get_table)}
    end
  end

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(@pubsub_name, state.node_db.values_pubsub_topic)
    Phoenix.PubSub.subscribe(@pubsub_name, state.node_db.error_pubsub_topic)

    # Remove any stale NodeTable entry before starting, so we always get a fresh table
    :ets.delete(:node_table_lookup, {:service, state.node_db.node_id})
    {:ok, table} = NodeTable.start({:service, state.node_db.node_id})

    values = get_val_map(state.node_db, table)

    state =
      state
      |> Map.put(:table, table)
      |> Map.put(:values, values)

    Logger.info(
      "Started NodeValues for Node: #{state.node_db.equipment_id} (#{state.node_db.uuid})"
    )

    {:ok, state}
  end

  @impl true
  def handle_info({:value_update, module, accessible, data_report}, state) do
    new_state =
      case value_update(state.values, state.node_db, state.table, module, accessible, data_report) do
        {:ok, :equal, _values} ->
          state

        {:ok, :updated, values} ->
          Map.put(state, :values, values)

        _ ->
          state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:error_update, module, accessible, error_report}, state) do
    # wrap error report in a tuple
    error_report = {:error_report, error_report}

    new_state =
      case value_update(
             state.values,
             state.node_db,
             state.table,
             module,
             accessible,
             error_report
           ) do
        {:ok, :equal, _values} ->
          state

        {:ok, :updated, values} ->
          Map.put(state, :values, values)

        _ ->
          state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_values, _from, state) do
    {:reply, state.values, state}
  end

  @impl true
  def handle_call(:get_node_db, _from, state) do
    {:reply, state.node_db, state}
  end

  def handle_call(:get_table, _from, state) do
    {:reply, state.table, state}
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

              {:error, :notfound} ->
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

  def value_update(values, node_db, table, module, accessible, data_report) do
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
          Phoenix.PubSub.broadcast(
            SecantService.PubSub,
            "value_update:processed:#{node_db.node_id_str}",
            {:value_update, :equal, module, accessible, new_param_val}
          )

          {:ok, :equal, values}
        else
          Phoenix.PubSub.broadcast(
            SecantService.PubSub,
            "value_update:processed:#{node_db.node_id_str}",
            {:value_update, :updated, module, accessible, new_param_val}
          )

          insert_parameter_value(table, module, accessible, merged_param_val)

          {:ok, :updated, put_in(values, [module, accessible], merged_param_val)}
        end
    end
  end

  # Remove timestamp from data_report qualifiers for comparison
  defp remove_timestamp(%{data_report: [value, qualifiers]} = param_val)
       when is_map(qualifiers) do
    Map.put(param_val, :data_report, [value, Map.drop(qualifiers, [:t])])
  end

  defp remove_timestamp(param_val), do: param_val

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

  def process_data_report(
        _accessible,
        {:error_report, [error_cls, error_msg, qualifiers]},
        datainfo
      ) do
    %{error_report: [error_cls, error_msg, qualifiers], datainfo: datainfo}
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
