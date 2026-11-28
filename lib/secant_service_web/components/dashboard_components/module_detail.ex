defmodule SecantServiceWeb.DashboardComponents.ModuleDetail do
  @moduledoc """
  Detail of one module: the live inspector and the data browser's main
  panel, and the resizable side panel around it.
  """
  use Phoenix.Component

  alias SecantService.Acquisition
  alias SecantService.Systems.Binding
  alias SecantServiceWeb.Systems
  alias SecantService.SecNodes.Module
  alias SecantService.Util
  alias SecantServiceWeb.ValueFormat
  alias SecantServiceWeb.Components.ModuleIndicator
  alias SecantServiceWeb.Components.CommandDisplay
  alias SecantServiceWeb.Components.HistoryDB
  alias SecantServiceWeb.Components.DashParameter

  import SecantServiceWeb.CoreComponents
  import SecantServiceWeb.SECoPComponents
  import SecantServiceWeb.DashboardComponents

  attr :module, :map, required: true
  attr :node, :map, required: true
  attr :mode, :atom, default: :live
  attr :plot_param, :string, default: nil
  attr :plot_id, :string, required: true
  attr :chart_height, :integer, default: 260
  attr :node_state, :atom, default: :initialized
  attr :bindings, :map, default: %{}, doc: "module name → SECoP system bindings"
  attr :matches, :map, default: %{}, doc: "module name → system match"

  def module_detail(assigns) do
    module = assigns.module
    plot_parameter = assigns.plot_param && Module.get_parameter(module, assigns.plot_param)

    module_json =
      case Map.get(assigns.node, :describe_message) do
        %{"modules" => modules} when is_map(modules) -> Map.get(modules, module.name)
        _ -> nil
      end

    assigns =
      assigns
      |> assign(:node_id_str, node_id_str(assigns.node))
      |> assign(:plot_parameter, plot_parameter)
      |> assign(:plot_obj, plot_parameter || module)
      |> assign(:has_value, Module.get_parameter(module, "value") != nil)
      |> assign(:param_groups, group_accessibles(sort_parameters(module.parameters)))
      |> assign(:command_groups, group_accessibles(module.commands))
      |> assign(:module_json, module_json && Jason.encode!(module_json, pretty: true))
      |> assign(:acq_channels, acq_channels(module, assigns.node.modules))
      |> assign(:acq_controller, Acquisition.controller_of(module, assigns.node.modules))
      |> assign(:module_bindings, Map.get(assigns.bindings, module.name, []))
      |> assign(:plot_spec, plot_spec(module, plot_parameter, assigns.matches))

    ~H"""
    <div class="flex flex-col gap-4" id={"module-detail-" <> @module.name}>
      <header>
        <div class="flex flex-wrap items-center gap-x-2.5 gap-y-1">
          <h2 class="text-lg font-bold tracking-tight">{Util.display_name(@module.name)}</h2>
          <span class="rounded bg-base-300 px-1.5 py-0.5 font-mono text-[11px] text-muted">
            {class_label(@module.highest_interface_class)}
          </span>
          <span class="flex-1"></span>
          <.live_component
            :if={@mode == :live and Module.has_status?(@module)}
            module={ModuleIndicator}
            id={"module_indicator_insp:" <> @node_id_str <> ":" <> @module.name}
            host={@node.host}
            port={@node.port}
            module_name={@module.name}
            highest_if_class={@module.highest_interface_class}
            status_param={Module.get_parameter(@module, "status")}
            node_state={@node_state}
            indicator_select={:compact}
          />
        </div>
        <div class="font-mono text-xs text-muted">{@node_id_str} · {@module.name}</div>
        <p :if={@module.description} class="mt-1 whitespace-pre-line text-muted">
          {String.trim(@module.description)}
        </p>
        <p :if={@acq_controller} id="acq-controller-link" class="mt-1 text-xs text-muted">
          Channel <span class="font-mono font-semibold">{elem(@acq_controller, 1)}</span>
          of acquisition
          <button
            phx-click="select_module"
            phx-value-module={elem(@acq_controller, 0).name}
            class="font-semibold text-base-content hover:underline"
          >
            {Util.display_name(elem(@acq_controller, 0).name)}
          </button>
        </p>
        <ul
          :if={@module_bindings != []}
          id="system-membership"
          class="mt-1 flex flex-col gap-0.5 text-xs text-muted"
          aria-label="Systems"
        >
          <li
            :for={binding <- @module_bindings}
            id={"system-membership-" <> binding.local_name}
            title={binding.description}
          >
            <span class="font-mono font-semibold text-base-content">{binding.role}</span>
            in <span class="font-semibold text-base-content">{binding.local_name}</span>
            <span class="font-mono">· {Binding.reference(binding)}</span>
            <span :for={parent <- binding.parents}>
              · <span class="font-mono font-semibold text-base-content">{parent.role}</span>
              of <span class="font-semibold text-base-content">{parent.local_name}</span>
              <span class="font-mono">· {parent.system}:{parent.version}</span>
            </span>
          </li>
        </ul>
      </header>

      <section :if={@acq_channels != []} id="acq-channel-links" aria-label="Acquisition channels">
        <h3 class="mb-1 text-[11px] font-semibold tracking-wider text-muted uppercase">
          Channels <span class="font-normal">· {length(@acq_channels)}</span>
        </h3>
        <div class="flex flex-wrap gap-1.5">
          <%= for {role, name, channel} <- @acq_channels do %>
            <button
              :if={channel}
              phx-click="select_module"
              phx-value-module={name}
              class="inline-flex items-baseline gap-1.5 rounded border border-line px-2 py-0.5 text-xs transition-colors hover:bg-base-200"
            >
              <span class="font-mono font-semibold">{role}</span>
              <span class="text-muted">{Util.display_name(name)}</span>
            </button>
            <span
              :if={!channel}
              class="inline-flex items-baseline gap-1.5 rounded border border-dashed border-line px-2 py-0.5 text-xs text-muted"
              title="Not a module of this node"
            >
              <span class="font-mono font-semibold">{role}</span>
              <span class="line-through">{name}</span>
            </span>
          <% end %>
        </div>
      </section>

      <section aria-label="Plot">
        <div class="mb-1.5 flex items-center gap-2 text-[11px] text-muted">
          <span class="font-semibold tracking-wider uppercase">Plot</span>
          <span class="font-mono">
            {if @plot_parameter, do: @plot_parameter.name, else: "module"}
          </span>
          <button
            :if={@plot_parameter}
            phx-click="plot_parameter"
            phx-value-param=""
            class="rounded px-1 hover:bg-base-300"
            title="Back to the module plot"
          >
            ✕ module plot
          </button>
        </div>
        <%= if @plot_parameter || @has_value do %>
          <.live_component
            module={HistoryDB}
            id={@plot_id}
            secop_obj={@plot_obj}
            plot_spec={@plot_spec}
            plot_mode={@mode}
            height={@chart_height}
            class=""
          />
        <% else %>
          <div class="rounded-box border border-dashed border-line px-3 py-6 text-center text-muted">
            This module has no <span class="font-mono">value</span>. Use a parameter's
            <.icon name="hero-chart-bar-micro" class="size-4" /> button to plot it.
          </div>
        <% end %>
      </section>

      <section :for={{group, params} <- @param_groups} aria-label="Parameters">
        <h3 class="mb-1 text-[11px] font-semibold tracking-wider text-muted uppercase">
          {if group, do: Util.display_name(group), else: "Parameters"}
          <span class="font-normal">· {length(params)}</span>
        </h3>
        <%= if @mode == :live do %>
          <.live_component
            :for={parameter <- params}
            module={DashParameter}
            id={"dash_parameter:" <> @node_id_str <> ":" <> @module.name <> ":" <> parameter.name}
            host={@node.host}
            port={@node.port}
            node_id_str={@node_id_str}
            module_name={@module.name}
            parameter={parameter}
            plotted={@plot_param == parameter.name}
          />
        <% else %>
          <.history_parameter
            :for={parameter <- params}
            parameter={parameter}
            plotted={@plot_param == parameter.name}
          />
        <% end %>
      </section>

      <section :for={{group, commands} <- @command_groups} aria-label="Commands">
        <h3 class="mb-1 text-[11px] font-semibold tracking-wider text-muted uppercase">
          {if group, do: "Commands · " <> Util.display_name(group), else: "Commands"}
          <span class="font-normal">· {length(commands)}</span>
        </h3>
        <%= if @mode == :live do %>
          <.live_component
            :for={command <- commands}
            module={CommandDisplay}
            id={"inspector:" <> @node_id_str <> ":" <> @module.name <> ":" <> command.name}
            class=""
            host={@node.host}
            port={@node.port}
            location="inspector"
            module_name={@module.name}
            command={command}
            variant={:row}
            id_str={"inspector:" <> @node_id_str <> ":" <> @module.name <> ":" <> command.name}
          />
        <% else %>
          <div :for={command <- commands} class="border-t border-line py-2 first:border-t-0">
            <div class="font-mono text-[13px] font-semibold">{command.name}</div>
            <div :if={command.description} class="text-xs text-muted">
              {command.description}
            </div>
            <div :if={command.datainfo["argument"]} class="font-mono text-xs text-muted">
              argument: {ValueFormat.type_label(command.datainfo["argument"])}
            </div>
          </div>
        <% end %>
      </section>

      <section aria-label="Module properties">
        <h3 class="mb-1 text-[11px] font-semibold tracking-wider text-muted uppercase">
          Module properties
        </h3>
        <dl class="text-xs">
          <.property prop_key="interface classes" value_class="font-mono text-xs">
            {Enum.join(@module.interface_classes || [], ", ")}
          </.property>
          <.property :if={@module.group} prop_key="group">{@module.group}</.property>
          <.property :if={@module.visibility} prop_key="visibility">{@module.visibility}</.property>
          <.property
            :if={@module.implementor}
            prop_key="implementor"
            value_class="font-mono text-xs break-all"
          >
            {@module.implementor}
          </.property>
          <.property :if={@module.meaning} prop_key="meaning" value_class="font-mono text-xs">
            {Util.short_inspect(@module.meaning)}
          </.property>
          <.custom_properties properties={@module.custom_properties} />
        </dl>
        <details :if={@module_json} class="mt-2 rounded border border-line">
          <summary class="cursor-pointer px-2 py-1 text-xs text-muted hover:bg-base-200">
            Description JSON
          </summary>
          <pre class="max-h-96 overflow-auto border-t border-line bg-base-200 p-2 font-mono text-xs">{@module_json}</pre>
        </details>
      </section>
    </div>
    """
  end

  attr :parameter, :map, required: true
  attr :plotted, :boolean, default: false

  # Parameter row in the data browser: metadata only, no live value.
  defp history_parameter(assigns) do
    datainfo = assigns.parameter.datainfo

    enum_members =
      case datainfo do
        %{"type" => "enum", "members" => members} -> Enum.sort_by(members, &elem(&1, 1))
        _ -> []
      end

    assigns =
      assigns
      |> assign(:type_label, ValueFormat.type_label(datainfo))
      |> assign(:limits, ValueFormat.limits(datainfo))
      |> assign(:unit, ValueFormat.unit(datainfo))
      |> assign(:enum_members, enum_members)

    ~H"""
    <div class="border-t border-line py-2.5 first:border-t-0" id={"param-row-" <> @parameter.name}>
      <div class="flex items-baseline gap-2">
        <span class="min-w-0 flex-1 font-mono text-[13px] font-semibold break-all">
          {@parameter.name}
        </span>
        <span class="font-mono text-xs text-muted">{@type_label}</span>
        <span :if={@unit != ""} class="font-mono text-xs text-muted">[{@unit}]</span>
        <span class="rounded border border-line px-1 font-mono text-[11px] text-muted">
          {if @parameter.readonly, do: "r", else: "r/w"}
        </span>
        <button
          type="button"
          phx-click="plot_parameter"
          phx-value-param={@parameter.name}
          class={[
            "rounded p-0.5 transition-colors hover:bg-base-300",
            if(@plotted, do: "text-ink", else: "text-muted")
          ]}
          aria-label={"Plot history of #{@parameter.name}"}
          title="Plot history"
        >
          <.icon name="hero-chart-bar-micro" class="size-4" />
        </button>
      </div>
      <div :if={@parameter.description} class="mt-0.5 text-xs text-muted">
        {@parameter.description}
      </div>
      <div :if={@limits} class="font-mono text-xs text-muted">range {@limits}</div>
      <div :if={@enum_members != []} class="mt-1 flex flex-wrap gap-1">
        <span
          :for={{name, code} <- @enum_members}
          class={["rounded border px-1.5 font-mono text-[11px]", ValueFormat.enum_class(code)]}
        >
          {name} <span class="opacity-70">{code}</span>
        </span>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Resizable side panel
  # ---------------------------------------------------------------------------

  attr :id, :string, required: true
  slot :inner_block, required: true

  @doc """
  Sticky panel on the right that scrolls on its own. Its width lives in the
  CSS variable `--inspector-w`, set by the ResizablePanel hook on the drag
  handle and remembered in the browser.
  """
  def inspector_panel(assigns) do
    ~H"""
    <aside
      id={@id}
      class="flex max-h-[calc(100vh-5.5rem)] w-full shrink-0 scroll-mt-[4.25rem] overflow-hidden rounded-box border border-line bg-base-100 lg:sticky lg:top-[4.25rem] lg:w-(--inspector-w) lg:max-w-[calc(100vw-18rem)] xl:max-w-[calc(100vw-34rem)]"
      aria-label="Selected module"
    >
      <div
        id={@id <> "-handle"}
        phx-hook="ResizablePanel"
        phx-update="ignore"
        role="separator"
        aria-orientation="vertical"
        aria-label="Drag to resize the module panel, double-click to reset"
        tabindex="0"
        class="hidden w-2.5 shrink-0 cursor-col-resize touch-none items-center justify-center border-r border-line bg-base-200 transition-colors hover:bg-base-300 xl:flex"
      >
        <span class="h-8 w-0.5 rounded bg-muted/60"></span>
      </div>
      <div class="min-w-0 flex-1 overflow-y-auto p-4">
        {render_slot(@inner_block)}
      </div>
    </aside>
    """
  end

  # value, target and status first, then the rest in description order
  defp sort_parameters(parameters) do
    order = %{"value" => 0, "target" => 1, "status" => 2}
    Enum.sort_by(parameters, fn p -> Map.get(order, p.name, 3) end)
  end

  # a matched system role's custom plot replaces the module plot (never a
  # parameter's own plot), for a module with a `value`: the plot's table and
  # export use `value`
  defp plot_spec(module, nil, matches) do
    if Module.get_parameter(module, "value"),
      do: Systems.plot(Map.get(matches, module.name))
  end

  defp plot_spec(_module, _plot_parameter, _matches), do: nil

  defp acq_channels(module, modules) do
    if Acquisition.controller?(module), do: Acquisition.channels(module, modules), else: []
  end
end
