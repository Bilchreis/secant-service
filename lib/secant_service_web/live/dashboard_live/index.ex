defmodule SecantServiceWeb.DashboardLive.Index do
  use SecantServiceWeb, :live_view

  alias SecantService.Model
  alias SecantClient
  alias SecantClient.NodeDiscover
  alias SecantClient.NodeSupervisor

  alias SecantService.Topics
  alias SecantServiceWeb.DashboardComponents
  alias SecantServiceWeb.SECoPComponents
  require Logger

  alias SecantClient.NodeStatem
  import SecantServiceWeb.SECoPComponents
  import SecantServiceWeb.DashboardComponents, only: [conn_state: 1]
  import SecantServiceWeb.DashboardComponents.NodeTabs
  import SecantServiceWeb.DashboardComponents.NodeHeader
  import SecantServiceWeb.DashboardComponents.ModuleRail
  import SecantServiceWeb.DashboardComponents.ModuleGrid
  import SecantServiceWeb.DashboardComponents.ModuleDetail

  defp subscribe_to_node(node_id) do
    Phoenix.PubSub.subscribe(SecantService.PubSub, Topics.processed_values(node_id))
    Phoenix.PubSub.subscribe(SecantService.PubSub, Topics.plot_data(node_id))
  end

  defp unsubscribe_from_node(node_id) do
    Phoenix.PubSub.unsubscribe(SecantService.PubSub, Topics.processed_values(node_id))
    Phoenix.PubSub.unsubscribe(SecantService.PubSub, Topics.plot_data(node_id))
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
    Phoenix.PubSub.subscribe(SecantService.PubSub, Topics.node_services())

    socket =
      socket
      |> Model.to_socket(model)
      |> assign(:show_connect_modal, false)
      |> assign(:hidden_node_ids, MapSet.new())
      |> assign(:selected_node_id, nil)
      |> assign(:selected_module, nil)
      |> assign(:plot_param, nil)
      |> assign(:status_map, %{})
      |> assign(:page_title, "Dashboard")

    {:ok, socket}
  end

  # (Re)load description and values of `node_id` from its running services and
  # point the value subscriptions at it.
  defp load_node(socket, node_id) do
    if current = socket.assigns.current_node, do: unsubscribe_from_node(current.node_id)

    # Subscribe before taking the snapshot so no update falls in between.
    subscribe_to_node(node_id)

    model =
      socket
      |> Model.from_socket()
      |> Model.set_current_node(node_id)

    if model.current_node == nil or model.current_node.node_id != node_id do
      unsubscribe_from_node(node_id)
      if model.current_node, do: subscribe_to_node(model.current_node.node_id)
    end

    socket
    |> Model.to_socket(model)
    |> assign(:status_map, status_map(model.values))
    |> assign_selected_module(socket.assigns.selected_module)
    |> drop_stale_plot_param()
  end

  # The plotted parameter may be gone after a description change.
  defp drop_stale_plot_param(%{assigns: %{plot_param: nil}} = socket), do: socket

  defp drop_stale_plot_param(socket) do
    %{current_node: node, selected_module: selected, plot_param: plot_param} = socket.assigns

    exists? =
      case selected_module(node, selected) do
        nil -> false
        module -> Enum.any?(module.parameters, &(&1.name == plot_param))
      end

    if exists?, do: socket, else: assign(socket, :plot_param, nil)
  end

  # "host:port"; the port is after the last colon so IPv6 hosts work too.
  defp parse_node_param(node_param) do
    with [_, host, port] <- Regex.run(~r/^(.+):(\d{1,5})$/, node_param),
         port = String.to_integer(port),
         true <- port in 1..65_535 do
      {:ok, {String.to_charlist(host), port}}
    else
      _ -> :error
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

        # Subscribe before taking the snapshot so no batch falls in between.
        subscribe_to_node(requested)

        # a node without running services has nothing to show: no current node
        model = Model.set_current_node(%{model | current_node: nil, values: nil}, requested)

        if model.current_node == nil, do: unsubscribe_from_node(requested)

        socket
        |> Model.to_socket(model)
        |> assign(:status_map, status_map(model.values))
      else
        socket
      end

    socket = assign(socket, :selected_node_id, requested)

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

  # Includes the uuid so a description change gives the history plot a fresh
  # component instead of one initialised for the old parameter records.
  def plot_id(node, module_name, plot_param) do
    "plot:#{node.uuid}:#{node.host}:#{node.port}:#{module_name}:#{plot_param || "module"}"
  end

  ### New Values Map Update

  @impl true
  def handle_info({:description_change, pubsub_topic, state}, socket) do
    Logger.info("node description change: #{pubsub_topic}")

    # Only the node list is updated here. The NodeManager restarts the node
    # services from the new description and then broadcasts
    # :node_services_ready, which is where the page reloads the node.
    node_id = pubsubtopic_to_node_id(pubsub_topic)
    active_nodes = Map.put(socket.assigns.active_nodes, node_id, Model.node_summary(state))

    {:noreply, assign(socket, active_nodes: active_nodes)}
  end

  def handle_info({:node_services_ready, node_id, uuid}, socket) do
    current_node = socket.assigns.current_node

    cond do
      # another node is selected and still waiting for its own services
      current_node == nil and socket.assigns.selected_node_id not in [nil, node_id] ->
        {:noreply, socket}

      current_node == nil ->
        Logger.info("Services for #{inspect(node_id)} ready (#{uuid}), showing node")
        {:noreply, socket |> load_node(node_id) |> assign(:selected_node_id, node_id)}

      current_node.node_id == node_id and current_node.uuid != uuid ->
        Logger.info("Services for #{inspect(node_id)} restarted (#{uuid}), reloading node")
        {:noreply, load_node(socket, node_id)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:node_services_stopped, _node_id}, socket) do
    # The node tab shows the connection state; keep the last known data.
    {:noreply, socket}
  end

  def handle_info({:conn_state, pubsub_topic, active}, socket) do
    Logger.info("Connection state change for '#{pubsub_topic}',to: Active == #{active}")

    active_nodes = socket.assigns.active_nodes

    new_active_nodes =
      case Map.fetch(active_nodes, pubsubtopic_to_node_id(pubsub_topic)) do
        {:ok, node} -> Map.put(active_nodes, node.node_id, Map.put(node, :active, active))
        :error -> active_nodes
      end

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
    active_nodes = socket.assigns.active_nodes |> Map.put(node_id, Model.node_summary(state))

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
      socket.assigns.active_nodes
      |> Map.put(pubsubtopic_to_node_id(pubsub_topic), Model.node_summary(state))

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

  # NodeValues publishes the changed values of a node in one batch per
  # interval (250 ms by default), the current value per parameter, so each viewer handles
  # a few messages per second however fast the node updates.
  @impl true
  def handle_info({:value_updates, node_id, batch}, socket) do
    values = socket.assigns.values

    socket =
      case socket.assigns.current_node do
        # a batch of the previous node can still be queued after a switch
        %{node_id: ^node_id, host: host, port: port} when is_map(values) ->
          node_id_str = "#{host}:#{port}"
          selected = socket.assigns.selected_module

          Enum.reduce(batch, socket, fn {{module, accessible}, data_report}, socket ->
            if Map.has_key?(values, module) do
              update_components(node_id_str, module, accessible, data_report, selected)
              put_status_color(socket, module, accessible, data_report)
            else
              socket
            end
          end)

        _ ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:plot_data, batch}, socket) do
    %{current_node: node, selected_module: selected, plot_param: plot_param} = socket.assigns

    for {module, accessible, data_report} <- batch do
      push_plot_data(node, selected, plot_param, module, accessible, data_report)
    end

    {:noreply, socket}
  end

  def handle_event("toggle-conn-state", _unsigned_params, socket) do
    with %{node_id: node_id} <- socket.assigns.current_node,
         %{node_id: node_id, active: active} <- socket.assigns.active_nodes[node_id] do
      Task.start(fn ->
        if active, do: NodeStatem.deactivate(node_id), else: NodeStatem.activate(node_id)
      end)
    end

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

    if current_node, do: unsubscribe_from_node(current_node.node_id)

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
    host = String.trim(params["host"] || "")

    case parse_node_param("#{host}:#{String.trim(params["port"] || "")}") do
      {:ok, {host, port}} ->
        NodeSupervisor.start_child(%{
          host: host,
          port: port,
          manual: true,
          reconnect_backoff: 5000
        })

        {:noreply, socket}

      :error ->
        {:noreply, put_flash(socket, :error, "Enter a host and a port between 1 and 65535")}
    end
  end

  defp pubsubtopic_to_node_id(pubsub_topic) do
    {:ok, node_id} = parse_node_param(pubsub_topic)
    node_id
  end

  # The module cards are rendered for every module, the inspector only for
  # the selected one: skip the inspector components of the others.
  defp update_components(node_id_str, module, accessible, data_report, selected) do
    update_cards(node_id_str, module, accessible, data_report)

    if module == selected do
      update_inspector(node_id_str, module, accessible, data_report)
    end
  end

  defp update_cards(node_id_str, module, "status", data_report) do
    send_update(SecantServiceWeb.Components.ModuleIndicator,
      id: "module_indicator:" <> node_id_str <> ":" <> module,
      value_update: data_report
    )

    send_update(SecantServiceWeb.Components.ModuleIndicator,
      id: "module_indicator_mod:" <> node_id_str <> ":" <> module,
      value_update: data_report
    )
  end

  defp update_cards(node_id_str, module, accessible, data_report)
       when accessible in ["value", "target"] do
    if accessible == "value",
      do: update_acquisition_goal(node_id_str, module, accessible, data_report)

    send_update(SecantServiceWeb.Components.ParameterValueDisplay,
      id: "module_dash:" <> node_id_str <> ":" <> module <> ":" <> accessible,
      value_update: data_report
    )
  end

  defp update_cards(node_id_str, module, accessible, data_report)
       when accessible in ["goal", "goal_enable"] do
    update_acquisition_goal(node_id_str, module, accessible, data_report)
  end

  defp update_cards(_node_id_str, _module, _accessible, _data_report), do: :ok

  defp update_inspector(node_id_str, module, accessible, data_report) do
    if accessible == "status" do
      send_update(SecantServiceWeb.Components.ModuleIndicator,
        id: "module_indicator_insp:" <> node_id_str <> ":" <> module,
        value_update: data_report
      )
    end

    send_update(SecantServiceWeb.Components.ParameterValueDisplay,
      id: "parameter_value:" <> node_id_str <> ":" <> module <> ":" <> accessible,
      value_update: data_report
    )
  end

  defp put_status_color(socket, module, "status", %{stat_color: color}),
    do: assign(socket, :status_map, Map.put(socket.assigns.status_map, module, color))

  defp put_status_color(socket, _module, _accessible, _data_report), do: socket

  defp push_plot_data(node, selected, plot_param, module, accessible, data_report) do
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
  end

  # goal progress on the acquisition channel tiles
  defp update_acquisition_goal(node_id_str, module, param, data_report) do
    send_update(SecantServiceWeb.Components.AcquisitionGoal,
      id: SecantServiceWeb.Components.AcquisitionGoal.id(node_id_str, module),
      param: param,
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
