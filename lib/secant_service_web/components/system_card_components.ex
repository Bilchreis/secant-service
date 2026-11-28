defmodule SecantServiceWeb.Systems.Components do
  @moduledoc """
  Building blocks for the bodies of custom system cards
  (`SecantServiceWeb.SystemRole`). They build the component ids the
  dashboard routes live values to, so a body only names what it shows.

  `card_param` and `card_command` ids include the host's `location`
  (`"module_dash"` on the dashboard). `card_status` and `card_sparkline` use
  the fixed ids today's routing reaches, so a page shows a module's status
  and sparkline at most once. `card_sparkline` draws the generic
  `value`/`target` trend.
  """
  use Phoenix.Component

  alias SecantService.SecNodes.Module
  alias SecantServiceWeb.Components.CommandDisplay
  alias SecantServiceWeb.Components.ModuleIndicator
  alias SecantServiceWeb.Components.ParameterValueDisplay
  alias SecantServiceWeb.Components.Sparkline
  alias SecantServiceWeb.DashboardComponents
  alias SecantServiceWeb.ValueFormat

  attr :node, :map, required: true
  attr :module, :map, required: true
  attr :location, :string, required: true
  attr :name, :string, required: true, doc: "the parameter; list it in `shown_parameters`"
  attr :variant, :atom, default: :row, doc: ":hero, :target or :row"
  attr :class, :string, default: ""

  @doc "A parameter's live value (and its set form when writable)."
  def card_param(assigns) do
    assigns =
      assigns
      |> assign(:parameter, Module.get_parameter(assigns.module, assigns.name))
      |> assign(:id, component_id(assigns, assigns.name))

    ~H"""
    <.live_component
      :if={@parameter}
      module={ParameterValueDisplay}
      id={@id}
      class={@class}
      host={@node.host}
      port={@node.port}
      location={@location}
      module_name={@module.name}
      parameter={@parameter}
      variant={@variant}
      id_str={@id}
    />
    """
  end

  attr :node, :map, required: true
  attr :module, :map, required: true
  attr :node_state, :atom, default: :initialized
  attr :select, :atom, default: :inner, doc: "the indicator's layout, :inner or :compact"

  @doc "The module's status indicator."
  def card_status(assigns) do
    ~H"""
    <.live_component
      :if={Module.has_status?(@module)}
      module={ModuleIndicator}
      id={"module_indicator_mod:" <> DashboardComponents.node_id_str(@node) <> ":" <> @module.name}
      host={@node.host}
      port={@node.port}
      module_name={@module.name}
      highest_if_class={@module.highest_interface_class}
      status_param={Module.get_parameter(@module, "status")}
      node_state={@node_state}
      indicator_select={@select}
    />
    """
  end

  attr :node, :map, required: true
  attr :module, :map, required: true

  @doc "The trend of the module's `value` (and `target`), as on the generic card."
  def card_sparkline(assigns) do
    assigns = assign(assigns, :value_param, Module.get_parameter(assigns.module, "value"))

    ~H"""
    <.live_component
      :if={@value_param && ValueFormat.numeric?(@value_param.datainfo)}
      module={Sparkline}
      id={DashboardComponents.sparkline_id(@node, @module.name)}
      value_param={@value_param}
      target_param={Module.get_parameter(@module, "target")}
    />
    """
  end

  attr :node, :map, required: true
  attr :module, :map, required: true
  attr :location, :string, required: true
  attr :name, :string, required: true
  attr :variant, :atom, default: :button

  @doc "A command button."
  def card_command(assigns) do
    assigns =
      assigns
      |> assign(:command, Enum.find(assigns.module.commands || [], &(&1.name == assigns.name)))
      |> assign(:id, component_id(assigns, assigns.name))

    ~H"""
    <.live_component
      :if={@command}
      module={CommandDisplay}
      id={@id}
      class=""
      host={@node.host}
      port={@node.port}
      location={@location}
      module_name={@module.name}
      command={@command}
      variant={@variant}
      id_str={@id}
    />
    """
  end

  defp component_id(assigns, name),
    do:
      assigns.location <>
        ":" <>
        DashboardComponents.node_id_str(assigns.node) <> ":" <> assigns.module.name <> ":" <> name
end
