defmodule SecantServiceWeb.DashboardLive.Index do
  use SecantServiceWeb, :live_view

  alias SecantService.Model
  alias SecantClient
  alias NodeDiscover
  alias SEC_Node_Supervisor

  alias SecantService.NodeValues
  alias SecantService.NodeSupervisor
  alias SecantServiceWeb.DashboardComponents
  alias SecantServiceWeb.SECoPComponents
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
      |> assign(:hidden_node_ids, MapSet.new())
      |> assign(:selected_module, nil)
      |> assign(:plot_param, nil)
      |> assign(:status_map, %{})
      |> assign(:page_title, "Dashboard")

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
  def handle_params(params, _uri, socket) do
    model = Model.from_socket(socket)

    requested =
      with node_param when is_binary(node_param) <- params["node"],
           {:ok, node_id} when is_map_key(model.active_nodes, node_id) <-
             parse_node_param(node_param) do
        node_id
      else
        _ -> Model.get_default_node_id(model)
      end

    current_id = model.current_node && model.current_node.node_id

    socket =
      if requested != nil and requested != current_id do
        if current_id, do: unsubscribe_from_node(current_id)

        model = Model.set_current_node(model, requested)

        if model.current_node do
          subscribe_to_node(model.current_node.node_id)
        end

        socket
        |> Model.to_socket(model)
        |> assign(:status_map, status_map(model.values))
      else
        socket
      end

    {:noreply, assign_selected_module(socket, params["module"])}
  end

  defp assign_selected_module(%{assigns: %{current_node: nil}} = socket, _name), do: socket

  defp assign_selected_module(socket, name) do
    modules = socket.assigns.current_node.modules

    selected =
      case Enum.find(modules, &(&1.name == name)) do
        nil ->
          case DashboardComponents.group_modules(modules) do
            [{_label, [first | _]} | _] -> first.name
            _ -> nil
          end

        module ->
          module.name
      end

    if selected == socket.assigns.selected_module do
      socket
    else
      socket
      |> assign(:selected_module, selected)
      |> assign(:plot_param, nil)
    end
  end

  # module name => status range atom (:idle, :busy, ...)
  defp status_map(nil), do: %{}

  defp status_map(values) do
    Map.new(values, fn {module, params} ->
      {module, get_in(params, ["status", :stat_color])}
    end)
  end

  @status_order [
    error: "error",
    warning: "warn",
    busy: "busy",
    idle: "idle",
    disabled: "disabled"
  ]

  @doc "Summary line for the node header, e.g. 12 idle · 1 busy."
  def status_counts(status_map) do
    freq = status_map |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.frequencies()

    for {key, label} <- @status_order, n = Map.get(freq, key), n do
      {"#{n} #{label}", SECoPComponents.status_to_color(key)}
    end
  end

  def selected_module(%{modules: modules}, name), do: Enum.find(modules, &(&1.name == name))
  def selected_module(_, _), do: nil

  def plot_id(node, module_name, plot_param) do
    "plot:#{node.host}:#{node.port}:#{module_name}:#{plot_param || "module"}"
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

          socket
          |> assign(current_node: current_node)
          |> assign(values: values)
          |> assign(:status_map, status_map(values))

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

          socket
          |> assign(current_node: current_node)
          |> assign(values: values)
          |> assign(:status_map, status_map(values))

        true ->
          Logger.info("Current node not updated #{inspect(node_id)}")
          socket
      end

    socket =
      socket
      |> assign(active_nodes: active_nodes)
      |> assign_selected_module(socket.assigns.selected_module)

    {:noreply, socket}
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
    plot_param =
      if socket.assigns.plot_param == parameter.name, do: nil, else: parameter.name

    {:noreply, assign(socket, :plot_param, plot_param)}
  end

  @impl true
  def handle_info({:put_flash, [type, message]}, socket) do
    Process.send_after(self(), :clear_flash, 5000)
    {:noreply, put_flash(socket, type, message)}
  end

  def handle_info(:clear_flash, socket) do
    {:noreply, clear_flash(socket)}
  end

  # a Set or command finished; release its lock even if the widget that
  # sent it is no longer on screen
  def handle_info({:in_flight_done, key}, socket) do
    SecantServiceWeb.InFlight.release(key)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:value_update, :updated, module, accessible, data_report}, socket) do
    values = socket.assigns.values

    if Map.has_key?(values, module) do
      node_id_str =
        "#{to_string(socket.assigns.current_node.host)}:#{socket.assigns.current_node.port}"

      update_components(
        node_id_str,
        module,
        accessible,
        data_report
      )

      socket =
        case {accessible, data_report} do
          {"status", %{stat_color: color}} ->
            assign(socket, :status_map, Map.put(socket.assigns.status_map, module, color))

          _ ->
            socket
        end

      {:noreply, socket}
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
    %{current_node: node, selected_module: selected, plot_param: plot_param} = socket.assigns

    if node && accessible in ["value", "target"] do
      send_update(SecantServiceWeb.Components.Sparkline,
        id: DashboardComponents.sparkline_id(node, module),
        append: data_report,
        series: accessible
      )
    end

    if node && module == selected do
      send_update(SecantServiceWeb.Components.HistoryDB,
        id: plot_id(node, module, plot_param),
        value_update: data_report,
        parameter: accessible
      )
    end

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
  def handle_event("toggle_hidden", %{"pstopic" => pubsub_topic}, socket) do
    node_id = pubsubtopic_to_node_id(pubsub_topic)
    hidden = socket.assigns.hidden_node_ids

    updated =
      if MapSet.member?(hidden, node_id) do
        MapSet.delete(hidden, node_id)
      else
        MapSet.put(hidden, node_id)
      end

    {:noreply, assign(socket, :hidden_node_ids, updated)}
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
  def handle_event("select_module", %{"module" => module}, socket) do
    node = socket.assigns.current_node

    {:noreply,
     socket
     |> push_patch(to: ~p"/dashboard?node=#{"#{node.host}:#{node.port}"}&module=#{module}")
     |> push_event("reveal-panel", %{id: "inspector"})}
  end

  @impl true
  def handle_event("plot_parameter", %{"param" => param}, socket) do
    plot_param = if param in ["", socket.assigns.plot_param], do: nil, else: param
    {:noreply, assign(socket, :plot_param, plot_param)}
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

    send_update(SecantServiceWeb.Components.ModuleIndicator,
      id: "module_indicator_insp:" <> node_id_str <> ":" <> module,
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
