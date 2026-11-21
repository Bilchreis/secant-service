defmodule SecantServiceWeb.DashboardComponents.ModuleGrid do
  @moduledoc "Card grid of the live dashboard: one card per module, acquisition cards for acquisition modules."
  use Phoenix.Component

  alias SecantService.Acquisition
  alias SecantService.SecNodes.Module
  alias SecantService.Util
  alias SecantServiceWeb.ValueFormat
  alias SecantServiceWeb.Components.ModuleIndicator
  alias SecantServiceWeb.Components.ParameterValueDisplay
  alias SecantServiceWeb.Components.CommandDisplay
  alias SecantServiceWeb.Components.Sparkline
  alias SecantServiceWeb.Components.AcquisitionGoal

  import SecantServiceWeb.DashboardComponents

  @card_commands ["stop", "go"]

  attr :node, :map, required: true
  attr :selected, :string, default: nil
  attr :status_map, :map, default: %{}, doc: "module name → status, for the card tint"

  attr :node_state, :atom,
    default: :initialized,
    doc: ":initialized, :paused or a disconnected state"

  def module_grid(assigns) do
    modules = assigns.node.modules
    # channels show inside their controller's card, not as cards of their own
    claimed = Acquisition.channel_names(modules)

    groups =
      modules
      |> Enum.reject(&MapSet.member?(claimed, &1.name))
      |> group_modules()
      |> Enum.map(fn {label, mods} ->
        {controllers, others} = Enum.split_with(mods, &Acquisition.controller?/1)
        {label, controllers, others}
      end)

    assigns = assign(assigns, :groups, groups)

    ~H"""
    <div id="module-grid" class="flex min-w-0 flex-col gap-5">
      <section :for={{label, controllers, modules} <- @groups}>
        <h2 class="mb-2 text-[11px] font-semibold tracking-wider text-muted uppercase">
          {label || "Modules"}
          <span class="font-normal">· {length(controllers) + length(modules)}</span>
        </h2>
        <div :if={controllers != []} class="mb-2.5 flex flex-col gap-2.5">
          <.acquisition_card
            :for={controller <- controllers}
            module={controller}
            node={@node}
            selected={@selected}
            node_state={@node_state}
            status_map={@status_map}
          />
        </div>
        <div
          :if={modules != []}
          class="grid grid-cols-[repeat(auto-fill,minmax(240px,1fr))] gap-2.5"
        >
          <.module_card
            :for={module <- modules}
            module={module}
            node={@node}
            selected={module.name == @selected}
            node_state={@node_state}
            status={Map.get(@status_map, module.name)}
          />
        </div>
      </section>
    </div>
    """
  end

  @acquisition_commands ["prepare", "go", "hold", "stop"]

  attr :module, :map, required: true, doc: "the AcquisitionController module"
  attr :node, :map, required: true
  attr :selected, :string, default: nil
  attr :node_state, :atom, default: :initialized
  attr :status_map, :map, default: %{}

  # An AcquisitionController with its channels (its `acquisition_channels`
  # property) as tiles. The channel tiles reuse the component ids of a plain
  # module card, so the dashboard's value routing reaches them unchanged.
  defp acquisition_card(assigns) do
    module = assigns.module

    commands =
      @acquisition_commands
      |> Enum.map(fn name -> Enum.find(module.commands, &(&1.name == name)) end)
      |> Enum.reject(&is_nil/1)

    assigns =
      assigns
      |> assign(:node_id_str, node_id_str(assigns.node))
      |> assign(:channels, Acquisition.channels(module, assigns.node.modules))
      |> assign(:commands, commands)
      |> assign(:other_commands, length(module.commands) - length(commands))
      |> assign(:status, assigns.node_state == :initialized && assigns.status_map[module.name])

    ~H"""
    <article
      id={"acq-" <> @module.name}
      class={[
        "relative flex min-w-0 flex-col gap-3 overflow-hidden rounded-box border p-3 transition-[color,background-color,border-color,opacity]",
        if(@module.name == @selected, do: "border-primary", else: "border-line"),
        card_tint(@status),
        @node_state != :initialized && "border-dashed opacity-75"
      ]}
      data-stale={to_string(@node_state != :initialized)}
      data-status={@status}
    >
      <span
        :if={@status in [:busy, :warning, :error]}
        class={["absolute inset-y-0 left-0 w-1", card_edge(@status)]}
        aria-hidden="true"
      ></span>
      <header class="flex flex-wrap items-start gap-x-4 gap-y-2">
        <button
          phx-click="select_module"
          phx-value-module={@module.name}
          class="min-w-0 text-left"
          title={@module.description}
        >
          <span class="block truncate text-[14px] font-semibold hover:underline">
            {Util.display_name(@module.name)}
          </span>
          <span class="block font-mono text-[11px] text-muted">
            {class_label(@module.highest_interface_class)} · {length(@channels)} {if length(@channels) ==
                                                                                       1,
                                                                                     do: "channel",
                                                                                     else: "channels"}
          </span>
        </button>
        <div :if={Module.has_status?(@module)} class="min-w-0 flex-1 basis-40">
          <.live_component
            module={ModuleIndicator}
            id={"module_indicator_mod:" <> @node_id_str <> ":" <> @module.name}
            host={@node.host}
            port={@node.port}
            module_name={@module.name}
            highest_if_class={@module.highest_interface_class}
            status_param={Module.get_parameter(@module, "status")}
            node_state={@node_state}
            indicator_select={:inner}
          />
        </div>
        <div class="ml-auto flex flex-wrap items-center gap-1.5">
          <.live_component
            :for={command <- @commands}
            module={CommandDisplay}
            id={"module_dash:" <> @node_id_str <> ":" <> @module.name <> ":" <> command.name}
            class=""
            host={@node.host}
            port={@node.port}
            location="module_dash"
            module_name={@module.name}
            command={command}
            variant={:button}
            id_str={"module_dash:" <> @node_id_str <> ":" <> @module.name <> ":" <> command.name}
          />
          <button
            phx-click="select_module"
            phx-value-module={@module.name}
            class="rounded px-1 py-0.5 text-xs text-muted hover:bg-base-200 hover:text-base-content"
          >
            {length(@module.parameters)} params<span :if={@other_commands > 0}> · {@other_commands} {if @other_commands ==
                                                                                                          1,
                                                                                                        do:
                                                                                                          "cmd",
                                                                                                        else:
                                                                                                          "cmds"}</span>
            ›
          </button>
        </div>
      </header>

      <div
        :if={@channels != []}
        class="grid grid-cols-[repeat(auto-fill,minmax(200px,1fr))] gap-2"
      >
        <%= for {role, name, channel} <- @channels do %>
          <.acquisition_channel
            :if={channel}
            role={role}
            module={channel}
            node={@node}
            node_id_str={@node_id_str}
            selected={name == @selected}
            node_state={@node_state}
            status={@node_state == :initialized && @status_map[name]}
          />
          <div
            :if={!channel}
            id={"acq-channel-missing-" <> name}
            class="rounded-box border border-dashed border-line p-2.5 text-xs text-muted"
          >
            <span class="font-mono font-semibold">{role}</span>
            → <span class="font-mono">{name}</span>
            is not a module of this node
          </div>
        <% end %>
      </div>
      <p :if={@channels == []} class="text-xs text-muted">
        No channels listed in <span class="font-mono">acquisition_channels</span>.
      </p>
    </article>
    """
  end

  attr :role, :string, required: true
  attr :module, :map, required: true
  attr :node, :map, required: true
  attr :node_id_str, :string, required: true
  attr :selected, :boolean, default: false
  attr :node_state, :atom, default: :initialized
  attr :status, :any, default: nil

  # One channel: role, own status (channels can be busy on their own, e.g. a
  # detector still counting), value, progress towards its goal and trend.
  defp acquisition_channel(assigns) do
    value_param = Module.get_parameter(assigns.module, "value")

    assigns =
      assigns
      |> assign(:value_param, value_param)
      |> assign(:has_goal, Module.get_parameter(assigns.module, "goal") != nil)

    ~H"""
    <div
      id={"acq-channel-" <> @module.name}
      class={[
        "relative flex min-w-0 flex-col gap-1.5 overflow-hidden rounded-box border bg-base-100 p-2.5 transition-colors",
        if(@selected, do: "border-primary", else: "border-line"),
        card_tint(@status)
      ]}
      data-status={@status}
    >
      <span
        :if={@status in [:busy, :warning, :error]}
        class={["absolute inset-y-0 left-0 w-1", card_edge(@status)]}
        aria-hidden="true"
      ></span>
      <div class="flex items-start gap-2">
        <button
          phx-click="select_module"
          phx-value-module={@module.name}
          class="min-w-0 flex-1 text-left"
          title={@module.description}
        >
          <span class="block truncate font-mono text-[13px] font-semibold hover:underline">
            {@role}
          </span>
          <span class="block truncate text-[11px] text-muted">
            {Util.display_name(@module.name)}
          </span>
        </button>
        <.live_component
          :if={Module.has_status?(@module)}
          module={ModuleIndicator}
          id={"module_indicator_mod:" <> @node_id_str <> ":" <> @module.name}
          host={@node.host}
          port={@node.port}
          module_name={@module.name}
          highest_if_class={@module.highest_interface_class}
          status_param={Module.get_parameter(@module, "status")}
          node_state={@node_state}
          indicator_select={:compact}
        />
      </div>

      <.live_component
        :if={@value_param}
        module={ParameterValueDisplay}
        id={"module_dash:" <> @node_id_str <> ":" <> @module.name <> ":value"}
        class=""
        host={@node.host}
        port={@node.port}
        location="module_dash"
        module_name={@module.name}
        parameter={@value_param}
        variant={:hero}
        id_str={"module_dash:" <> @node_id_str <> ":" <> @module.name <> ":value"}
      />

      <.live_component
        :if={@has_goal}
        module={AcquisitionGoal}
        id={AcquisitionGoal.id(@node_id_str, @module.name)}
        host={@node.host}
        port={@node.port}
        channel={@module}
      />

      <.live_component
        :if={@value_param && ValueFormat.numeric?(@value_param.datainfo)}
        module={Sparkline}
        id={sparkline_id(@node, @module.name)}
        value_param={@value_param}
        target_param={nil}
      />
    </div>
    """
  end

  attr :module, :map, required: true
  attr :node, :map, required: true
  attr :selected, :boolean, default: false
  attr :node_state, :atom, default: :initialized
  attr :status, :atom, default: nil, doc: "SECoP status range: :idle, :busy, :warning, :error"

  def module_card(assigns) do
    module = assigns.module
    value_param = Module.get_parameter(module, "value")
    target_param = Module.get_parameter(module, "target")

    card_commands =
      module.commands
      |> Enum.filter(&(&1.name in @card_commands))
      |> Enum.sort_by(&(&1.name != "stop"))

    other_commands = length(module.commands) - length(card_commands)

    assigns =
      assigns
      |> assign(:node_id_str, node_id_str(assigns.node))
      |> assign(:value_param, value_param)
      |> assign(:target_param, if(target_param && not target_param.readonly, do: target_param))
      |> assign(:card_commands, card_commands)
      |> assign(:other_commands, other_commands)
      |> assign(:has_status, Module.has_status?(module))

    ~H"""
    <article
      id={"card-" <> @module.name}
      class={[
        "relative flex min-w-0 flex-col gap-2 overflow-hidden rounded-box border p-3 transition-[color,background-color,border-color,opacity]",
        if(@selected, do: "border-primary", else: "border-line"),
        card_tint(@node_state == :initialized && @status),
        @node_state != :initialized && "border-dashed opacity-75"
      ]}
      data-stale={to_string(@node_state != :initialized)}
      data-status={@status}
    >
      <span
        :if={@node_state == :initialized && @status in [:busy, :warning, :error]}
        class={["absolute inset-y-0 left-0 w-1", card_edge(@status)]}
        aria-hidden="true"
      ></span>
      <header class="flex items-start gap-2">
        <button
          phx-click="select_module"
          phx-value-module={@module.name}
          class="min-w-0 flex-1 text-left"
          title={@module.description}
        >
          <span class="block truncate text-[14px] font-semibold hover:underline">
            {Util.display_name(@module.name)}
          </span>
          <span class="block font-mono text-[11px] text-muted">
            {class_label(@module.highest_interface_class)}
          </span>
        </button>
      </header>

      <.live_component
        :if={@has_status}
        module={ModuleIndicator}
        id={"module_indicator_mod:" <> @node_id_str <> ":" <> @module.name}
        host={@node.host}
        port={@node.port}
        module_name={@module.name}
        highest_if_class={@module.highest_interface_class}
        status_param={Module.get_parameter(@module, "status")}
        node_state={@node_state}
        indicator_select={:inner}
      />

      <.live_component
        :if={@value_param}
        module={ParameterValueDisplay}
        id={"module_dash:" <> @node_id_str <> ":" <> @module.name <> ":value"}
        class=""
        host={@node.host}
        port={@node.port}
        location="module_dash"
        module_name={@module.name}
        parameter={@value_param}
        variant={:hero}
        id_str={"module_dash:" <> @node_id_str <> ":" <> @module.name <> ":value"}
      />

      <.live_component
        :if={@target_param}
        module={ParameterValueDisplay}
        id={"module_dash:" <> @node_id_str <> ":" <> @module.name <> ":target"}
        class=""
        host={@node.host}
        port={@node.port}
        location="module_dash"
        module_name={@module.name}
        parameter={@target_param}
        variant={:target}
        id_str={"module_dash:" <> @node_id_str <> ":" <> @module.name <> ":target"}
      />

      <.live_component
        :if={@value_param && ValueFormat.numeric?(@value_param.datainfo)}
        module={Sparkline}
        id={sparkline_id(@node, @module.name)}
        value_param={@value_param}
        target_param={Module.get_parameter(@module, "target")}
      />

      <footer class="mt-auto flex flex-wrap items-center gap-1.5 border-t border-line pt-2">
        <.live_component
          :for={command <- @card_commands}
          module={CommandDisplay}
          id={"module_dash:" <> @node_id_str <> ":" <> @module.name <> ":" <> command.name}
          class=""
          host={@node.host}
          port={@node.port}
          location="module_dash"
          module_name={@module.name}
          command={command}
          variant={:button}
          id_str={"module_dash:" <> @node_id_str <> ":" <> @module.name <> ":" <> command.name}
        />
        <span class="flex-1"></span>
        <button
          phx-click="select_module"
          phx-value-module={@module.name}
          class="rounded px-1 py-0.5 text-xs text-muted hover:bg-base-200 hover:text-base-content"
        >
          {length(@module.parameters)} params<span :if={@other_commands > 0}> · {@other_commands} {if @other_commands ==
                                                                                                        1,
                                                                                                      do:
                                                                                                        "cmd",
                                                                                                      else:
                                                                                                        "cmds"}</span>
          ›
        </button>
      </footer>
    </article>
    """
  end

  # warn and error tint the whole card; busy only gets the edge
  defp card_tint(:error), do: "bg-st-error/8"
  defp card_tint(:warning), do: "bg-st-warn/8"
  defp card_tint(_), do: "bg-base-100"

  defp card_edge(:error), do: "bg-st-error"
  defp card_edge(:warning), do: "bg-st-warn"
  defp card_edge(_), do: "bg-st-busy"
end
