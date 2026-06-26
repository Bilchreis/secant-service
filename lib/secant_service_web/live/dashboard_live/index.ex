defmodule SecantServiceWeb.DashboardLive.Index do
  use SecantServiceWeb, :live_view

  alias SecantService.Model
  alias SecantClient
  alias NodeDiscover
  alias SEC_Node_Supervisor

  alias SecantService.NodeValues
  alias SecantService.NodeSupervisor
  alias SecantServiceWeb.Components.HistoryDB
  require Logger

  alias SEC_Node_Statem
  import SecantServiceWeb.SECoPComponents
  import SecantServiceWeb.DashboardComponents

  defp subscribe_to_node(node_id) do
    Phoenix.PubSub.subscribe(
      SecantService.PubSub,
      "value_update:processed:#{elem(node_id, 0)}:#{elem(node_id, 1)}"
    )

    Phoenix.PubSub.subscribe(
      SecantService.PubSub,
      "plot_data:#{elem(node_id, 0)}:#{elem(node_id, 1)}"
    )
  end

  defp unsubscribe_from_node(node_id) do
    Phoenix.PubSub.unsubscribe(
      SecantService.PubSub,
      "value_update:processed:#{elem(node_id, 0)}:#{elem(node_id, 1)}"
    )

    Phoenix.PubSub.unsubscribe(
      SecantService.PubSub,
      "plot_data:#{elem(node_id, 0)}:#{elem(node_id, 1)}"
    )
  end

  @impl true
  def mount(_params, _session, socket) do
    model = Model.get_initial_model()

    if model.active_nodes == %{} do
      Logger.info("No active nodes detected")
    end

    Phoenix.PubSub.subscribe(:secant_client_pubsub, "descriptive_data_change")
    Phoenix.PubSub.subscribe(:secant_client_pubsub, "state_change")
    Phoenix.PubSub.subscribe(:secant_client_pubsub, "secop_conn_state")
    Phoenix.PubSub.subscribe(:secant_client_pubsub, "new_node")

    socket =
      socket
      |> Model.to_socket(model)
      |> assign(:show_connect_modal, false)
      |> assign(:selected_parameter, nil)

    {:ok, socket}
  end

  defp parse_node_param(node_param) do
    case String.split(node_param, ":") do
      [host, port] ->
        {:ok, {String.to_charlist(host), String.to_integer(port)}}

      _ ->
        :error
    end
  end

  @impl true
  def handle_params(unsigned_params, _uri, socket) do
    model = Model.from_socket(socket)

    model =
      case unsigned_params do
        %{"node" => node_param} ->
          # Parse node from URL like "?node=192.168.1.1:5000"
          case parse_node_param(node_param) do
            {:ok, node_id} when is_map_key(model.active_nodes, node_id) ->
              Model.set_current_node(model, node_id)

            _ ->
              # Invalid node, use default
              default_node_id = Model.get_default_node_id(model)
              Model.set_current_node(model, default_node_id)
          end

        _ ->
          # No node in URL, use default
          default_node_id = Model.get_default_node_id(model)
          Model.set_current_node(model, default_node_id)
      end

    if model.current_node do
      subscribe_to_node(model.current_node.node_id)
    end

    socket =
      socket
      |> Model.to_socket(model)

    {:noreply, socket}
  end

  ### New Values Map Update

  @impl true
  def handle_info({:description_change, pubsub_topic, state}, socket) do
    Logger.info("node state change: #{pubsub_topic} #{state.state}")

    node_id = pubsubtopic_to_node_id(pubsub_topic)

    updated_node =
      socket.assigns.active_nodes[node_id]
      |> Map.put(:description, state.description)
      |> Map.put(:equipment_id, state.equipment_id)
      |> Map.put(:raw_description, state.raw_description)
      |> Map.put(:uuid, state.uuid)

    active_nodes = socket.assigns.active_nodes |> Map.put(node_id, updated_node)
    current_node = socket.assigns.current_node
    values = socket.assigns.values

    socket =
      cond do
        current_node == nil ->
          Logger.info("No current node set, yet (possibly first node connected)")

          {values, current_node} =
            if NodeSupervisor.services_running?(state[:uuid]) do
              {:ok, current_node} = NodeValues.get_node_db(node_id)
              {:ok, values} = NodeValues.get_values(node_id)

              subscribe_to_node(node_id)

              Logger.info("Current node updated #{inspect(node_id)}")
              {values, current_node}
            else
              Logger.warning(
                "Node with UUID #{state[:uuid]} does not exist in the database, retrying..."
              )

              Process.send_after(self(), {:description_change, pubsub_topic, state}, 500)
              {values, current_node}
            end

          assign(socket, current_node: current_node) |> assign(values: values)

        state.node_id == current_node.node_id ->
          {values, current_node} =
            if NodeSupervisor.services_running?(state[:uuid]) do
              # unsubscribe from all subs (prevents double updates)
              unsubscribe_from_node(current_node.node_id)
              {:ok, current_node} = NodeValues.get_node_db(node_id)
              {:ok, values} = NodeValues.get_values(node_id)

              subscribe_to_node(node_id)

              Logger.info("Current node updated #{inspect(node_id)}")
              {values, current_node}
            else
              unsubscribe_from_node(current_node.node_id)

              Logger.warning(
                "Node with UUID #{state[:uuid]} does not exist in the database, unsubscribed from pubsub topic."
              )

              Process.send_after(self(), {:description_change, pubsub_topic, state}, 500)
              {values, current_node}
            end

          assign(socket, current_node: current_node) |> assign(values: values)

        true ->
          Logger.info("Current node not updated #{inspect(node_id)}")
          socket
      end

    {:noreply, assign(socket, active_nodes: active_nodes)}
  end

  def handle_info({:conn_state, pubsub_topic, active}, socket) do
    Logger.info("Connection state change for '#{pubsub_topic}',to: Active == #{active}")

    active_nodes = socket.assigns.active_nodes

    updated_node =
      socket.assigns.active_nodes[pubsubtopic_to_node_id(pubsub_topic)]
      |> Map.put(:active, active)

    new_active_nodes = Map.put(active_nodes, pubsubtopic_to_node_id(pubsub_topic), updated_node)

    socket =
      socket
      |> assign(
        :active_nodes,
        new_active_nodes
      )

    {:noreply, socket}
  end

  def handle_info({:state_change, pubsub_topic, state}, socket) do
    Logger.info("node state change: #{pubsub_topic} #{state.state}")

    node_id = pubsubtopic_to_node_id(pubsub_topic)
    active_nodes = socket.assigns.active_nodes |> Map.put(node_id, state)

    {:noreply, assign(socket, active_nodes: active_nodes)}
  end

  def handle_info({:new_node, pubsub_topic, :connection_failed}, socket) do
    Logger.info("connection to: #{pubsub_topic} could not be established")
    send(self(), {:put_flash, [:error, "Connection to node '#{pubsub_topic}' failed."]})

    {:noreply, socket}
  end

  def handle_info({:new_node, pubsub_topic, state}, socket) do
    Logger.info("new node discovered: #{pubsub_topic} #{inspect(state)}")

    active_nodes =
      socket.assigns.active_nodes |> Map.put(pubsubtopic_to_node_id(pubsub_topic), state)

    socket =
      if socket.assigns.show_connect_modal do
        socket |> assign(show_connect_modal: false)
      else
        send(self(), {:put_flash, [:info, "New node '#{pubsub_topic}' discovered."]})
        socket
      end

    {:noreply, assign(socket, active_nodes: active_nodes)}
  end

  @impl true
  def handle_info({:show_parameter_graph, parameter}, socket) do
    {:noreply, assign(socket, :selected_parameter, parameter)}
  end

  @impl true
  def handle_info({:put_flash, [type, message]}, socket) do
    Process.send_after(self(), :clear_flash, 5000)
    {:noreply, put_flash(socket, type, message)}
  end

  def handle_info(:clear_flash, socket) do
    {:noreply, clear_flash(socket)}
  end

  @impl true
  def handle_info({:value_update, :updated, module, accessible, data_report}, socket) do
    values = socket.assigns.values

    if Map.has_key?(values, module) do
      put_in(values, [module, accessible], data_report)

      node_id_str =
        "#{to_string(socket.assigns.current_node.host)}:#{socket.assigns.current_node.port}"

      update_components(
        node_id_str,
        module,
        accessible,
        data_report
      )

      {:noreply, assign(socket, :values, values)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:value_update, :equal, _module, _accessible, _data_report}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:plot_data, module, accessible, data_report}, socket) do
    send_update(SecantServiceWeb.Components.HistoryDB,
      id: "module-plot:#{module}",
      value_update: data_report,
      parameter: accessible
    )

    {:noreply, socket}
  end

  def handle_event("toggle-conn-state", _unsigned_params, socket) do
    Logger.info("Toggling connection state for current node")

    node_state = socket.assigns.active_nodes[socket.assigns.current_node.node_id]
    node_id = node_state.node_id
    active = node_state.active

    Task.start(fn ->
      case active do
        true ->
          SEC_Node_Statem.deactivate(node_id)

        false ->
          SEC_Node_Statem.activate(node_id)
      end
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("node-select", %{"pstopic" => new_pubsub_topic}, socket) do
    # unsubscribe from the current node's pubsub topic
    Logger.info("Switching to node with pubsub topic: #{new_pubsub_topic}")

    current_node = socket.assigns.current_node

    unsubscribe_from_node(current_node.node_id)

    # Use push_navigate instead of push_patch to force a full re-mount
    {:noreply, push_navigate(socket, to: ~p"/dashboard?node=#{new_pubsub_topic}")}
  end

  @impl true
  def handle_event("set_parameter", unsigned_params, socket) do
    send_update(SecantServiceWeb.Components.ParameterValueDisplay,
      id: "#{unsigned_params["location"]}:" <> path_from_unsigned_params(unsigned_params),
      control: :set_parameter,
      unsigned_params: unsigned_params
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event("purge_plots", _params, socket) do
    Logger.info("Purging all plots...")
    {:noreply, push_event(socket, "cleanup-charts", %{})}
  end

  @impl true
  def handle_event("validate_parameter", unsigned_params, socket) do
    send_update(SecantServiceWeb.Components.ParameterValueDisplay,
      id: "#{unsigned_params["location"]}:" <> path_from_unsigned_params(unsigned_params),
      control: :validate,
      unsigned_params: unsigned_params
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_parameter_graph", _params, socket) do
    {:noreply, assign(socket, :selected_parameter, nil)}
  end

  @impl true
  def handle_event("open_connect_modal", _params, socket) do
    {:noreply,
     assign(socket,
       show_connect_modal: true
     )}
  end

  @impl true
  def handle_event("close_connect_modal", _params, socket) do
    {:noreply, assign(socket, show_connect_modal: false)}
  end

  def handle_event("trigger-node-scan", _params, socket) do
    Logger.info("Triggering node scan...")
    NodeDiscover.scan()
    {:noreply, socket}
  end

  def handle_event("connect-node", params, socket) do
    opts = %{
      host: params["host"] |> String.to_charlist(),
      port: params["port"] |> String.to_integer(),
      manual: true,
      reconnect_backoff: 5000
    }

    SEC_Node_Supervisor.start_child(opts)
    {:noreply, socket}
  end

  defp pubsubtopic_to_node_id(pubsub_topic) do
    [ip, port] = String.split(pubsub_topic, ":")
    {String.to_charlist(ip), String.to_integer(port)}
  end

  def update_components(node_id_str, module, "status", data_report) do
    send_update(SecantServiceWeb.Components.ModuleIndicator,
      id: "module_indicator:" <> node_id_str <> ":" <> module,
      value_update: data_report
    )

    send_update(SecantServiceWeb.Components.ModuleIndicator,
      id: "module_indicator_mod:" <> node_id_str <> ":" <> module,
      value_update: data_report
    )

    send_update(SecantServiceWeb.Components.ParameterValueDisplay,
      id: "parameter_value:" <> node_id_str <> ":" <> module <> ":" <> "status",
      value_update: data_report
    )
  end

  def update_components(node_id_str, module, "value", data_report) do
    send_update(SecantServiceWeb.Components.ParameterValueDisplay,
      id: "module_dash:" <> node_id_str <> ":" <> module <> ":" <> "value",
      value_update: data_report
    )

    send_update(SecantServiceWeb.Components.ParameterValueDisplay,
      id: "parameter_value:" <> node_id_str <> ":" <> module <> ":" <> "value",
      value_update: data_report
    )
  end

  def update_components(node_id_str, module, "target", data_report) do
    send_update(SecantServiceWeb.Components.ParameterValueDisplay,
      id: "parameter_value:" <> node_id_str <> ":" <> module <> ":" <> "target",
      value_update: data_report
    )

    send_update(SecantServiceWeb.Components.ParameterValueDisplay,
      id: "module_dash:" <> node_id_str <> ":" <> module <> ":" <> "target",
      value_update: data_report
    )
  end

  def update_components(node_id_str, module, accessible, data_report) do
    send_update(SecantServiceWeb.Components.ParameterValueDisplay,
      id: "parameter_value:" <> node_id_str <> ":" <> module <> ":" <> accessible,
      value_update: data_report
    )
  end

  # defp remove_last_segment(topic) do
  #  parts = String.split(topic, ":")
  #  parts |> Enum.drop(-1) |> Enum.join(":")
  # end

  defp path_from_unsigned_params(unsigned_params) do
    host = unsigned_params["host"]
    port = unsigned_params["port"]
    module = unsigned_params["module"]
    parameter = unsigned_params["parameter"]

    "#{host}:#{port}:#{module}:#{parameter}"
  end
end
