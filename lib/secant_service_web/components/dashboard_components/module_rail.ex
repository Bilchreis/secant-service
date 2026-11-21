defmodule SecantServiceWeb.DashboardComponents.ModuleRail do
  @moduledoc "List of a node's modules, grouped, with their status (live and historical)."
  use Phoenix.Component

  alias SecantService.SecNodes.Module
  alias SecantService.Util
  alias SecantServiceWeb.Components.ModuleIndicator

  import SecantServiceWeb.DashboardComponents

  attr :node, :map, required: true
  attr :selected, :string, default: nil
  attr :mode, :atom, default: :live
  attr :node_state, :atom, default: :initialized

  attr :class, :any, default: nil

  def module_rail(assigns) do
    assigns =
      assigns
      |> assign(:groups, group_modules(assigns.node.modules))
      |> assign(:node_id_str, node_id_str(assigns.node))

    ~H"""
    <aside
      id="module-rail"
      class={[
        "w-full rounded-box border border-line bg-base-100 p-2 max-lg:columns-2 max-lg:gap-x-4 sm:max-lg:columns-3 lg:sticky lg:top-[4.25rem] lg:z-[1] lg:max-h-[calc(100vh-5.5rem)] lg:w-60 lg:shrink-0 lg:overflow-y-auto",
        @class
      ]}
      aria-label="Modules"
    >
      <div class="px-1.5 pt-1 pb-1 text-[11px] font-semibold tracking-wider text-muted uppercase [column-span:all]">
        Modules · {length(@node.modules)}
      </div>
      <div :for={{label, modules} <- @groups} class="mt-2">
        <div :if={label} class="break-after-avoid px-1.5 pb-1 text-xs text-muted">{label}</div>
        <button
          :for={module <- modules}
          id={"rail-" <> module.name}
          phx-click="select_module"
          phx-value-module={module.name}
          aria-current={if(module.name == @selected, do: "true")}
          class={[
            "flex min-h-8 w-full break-inside-avoid items-center gap-2 rounded-md px-1.5 py-1 text-left transition-colors",
            if(module.name == @selected,
              do: "bg-base-300 font-semibold",
              else: "hover:bg-base-200"
            )
          ]}
        >
          <%= if @mode == :live do %>
            <.live_component
              module={ModuleIndicator}
              id={"module_indicator:" <> @node_id_str <> ":" <> module.name}
              host={@node.host}
              port={@node.port}
              module_name={module.name}
              highest_if_class={module.highest_interface_class}
              status_param={Module.get_parameter(module, "status")}
              node_state={@node_state}
              indicator_select={:outer}
            />
          <% else %>
            <span class="min-w-0 flex-1 truncate">{Util.display_name(module.name)}</span>
            <span class="shrink-0 font-mono text-[11px] text-muted">
              {class_label(module.highest_interface_class)}
            </span>
          <% end %>
        </button>
      </div>
    </aside>
    """
  end
end
