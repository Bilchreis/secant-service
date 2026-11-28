defmodule SecantServiceWeb.NodeBrowserLive.Index do
  @moduledoc """
  Historical view of one recorded SEC node: the same header and module rail
  as the live dashboard, with the selected module's history as the main
  panel (no live values, no controls).
  """
  use SecantServiceWeb, :live_view

  alias SecantService.SecNodes
  alias SecantServiceWeb.DashboardComponents

  import SecantServiceWeb.DashboardComponents.NodeHeader
  import SecantServiceWeb.DashboardComponents.ModuleRail
  import SecantServiceWeb.DashboardComponents.ModuleDetail

  @impl true
  def mount(params, _session, socket) do
    node =
      case SecNodes.get_sec_node(params["uuid"]) do
        {:ok, node} -> node
        {:error, _reason} -> nil
      end

    socket =
      socket
      |> assign(:node, node)
      |> assign(:systems, systems_for(node))
      |> assign(:selected_module, nil)
      |> assign(:plot_param, nil)
      |> assign(:page_title, if(node, do: node.equipment_id, else: "Node not found"))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, %{assigns: %{node: nil}} = socket) do
    _ = params
    {:noreply, socket}
  end

  def handle_params(params, _uri, socket) do
    modules = socket.assigns.node.modules

    selected =
      case Enum.find(modules, &(&1.name == params["module"])) do
        nil ->
          case DashboardComponents.group_modules(modules) do
            [{_label, [first | _]} | _] -> first.name
            _ -> nil
          end

        module ->
          module.name
      end

    socket =
      if selected == socket.assigns.selected_module do
        socket
      else
        socket |> assign(:selected_module, selected) |> assign(:plot_param, nil)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_module", %{"module" => module}, socket) do
    {:noreply,
     push_patch(socket, to: ~p"/browse/node/#{socket.assigns.node.uuid}?module=#{module}")}
  end

  @impl true
  def handle_event("plot_parameter", %{"param" => param}, socket) do
    plot_param = if param in ["", socket.assigns.plot_param], do: nil, else: param
    {:noreply, assign(socket, :plot_param, plot_param)}
  end

  def selected_module(%{modules: modules}, name), do: Enum.find(modules, &(&1.name == name))

  # the recorded node's SECoP system bindings and matched role modules, for
  # the module panel's membership and custom module plot
  defp systems_for(nil), do: %{bindings: %{}, matches: %{}}

  defp systems_for(node) do
    bindings = SecantService.Systems.bindings(node)
    %{bindings: bindings, matches: SecantServiceWeb.Systems.matches(node, bindings)}
  end

  def plot_id(node, module_name, plot_param) do
    "hplot:#{node.uuid}:#{module_name}:#{plot_param || "module"}"
  end
end
