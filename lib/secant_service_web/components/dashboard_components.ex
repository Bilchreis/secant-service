defmodule SecantServiceWeb.DashboardComponents do
  @moduledoc """
  Layout pieces of the node views. The live dashboard and the data browser
  share the node header, the module rail and the module detail panel; the
  card grid is live only.

  Everything is rendered from the node's self-description, so nothing here
  may assume a particular module or parameter beyond what SECoP defines
  (`value`, `target`, `status`, `stop`, `go`).
  """
  use Phoenix.Component

  alias SecantService.SecNodes.Module
  alias SecantService.Util
  alias SecantServiceWeb.ValueFormat
  alias SecantServiceWeb.Components.ModuleIndicator
  alias SecantServiceWeb.Components.ParameterValueDisplay
  alias SecantServiceWeb.Components.CommandDisplay
  alias SecantServiceWeb.Components.HistoryDB
  alias SecantServiceWeb.Components.DashParameter
  alias SecantServiceWeb.Components.Sparkline

  import SecantServiceWeb.CoreComponents
  import SecantServiceWeb.SECoPComponents

  @card_commands ["stop", "go"]

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Groups modules by their SECoP `group` property, ungrouped modules last.
  Returns `[{label, modules}]`.
  """
  def group_modules(modules) do
    {ungrouped, grouped} =
      modules
      |> Enum.sort_by(&natural_key(&1.name))
      |> Enum.group_by(& &1.group)
      |> Map.pop(nil, [])

    grouped =
      grouped
      |> Enum.sort_by(fn {group, _} -> String.downcase(group) end)
      |> Enum.map(fn {group, mods} -> {Util.display_name(group), mods} end)

    case ungrouped do
      [] -> grouped
      mods -> grouped ++ [{if(grouped == [], do: nil, else: "Ungrouped"), mods}]
    end
  end

  # "contr10" sorts after "contr9"
  defp natural_key(name) do
    ~r/(\d+)/
    |> Regex.split(String.downcase(name), include_captures: true, trim: true)
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {n, ""} -> {0, n, ""}
        _ -> {1, 0, part}
      end
    end)
  end

  @doc "Groups parameters or commands by their SECoP `group`, ungrouped first."
  def group_accessibles(accessibles) do
    {ungrouped, grouped} =
      accessibles
      |> Enum.group_by(& &1.group)
      |> Map.pop(nil, [])

    grouped = Enum.sort_by(grouped, fn {group, _} -> String.downcase(group) end)

    case ungrouped do
      [] -> grouped
      items -> [{nil, items} | grouped]
    end
  end

  # value, target and status first, then the rest in description order
  defp sort_parameters(parameters) do
    order = %{"value" => 0, "target" => 1, "status" => 2}
    Enum.sort_by(parameters, fn p -> Map.get(order, p.name, 3) end)
  end

  defp class_label(nil), do: "module"
  defp class_label(class), do: class

  def node_id_str(node), do: "#{node.host}:#{node.port}"

  @doc "DOM/component id of a card's sparkline; the dashboard routes plot data to it."
  def sparkline_id(node, module_name), do: "spark:#{node.host}:#{node.port}:#{module_name}"

  # descriptions often contain blank lines; keep line breaks, drop the gaps
  defp compact_text(text) do
    text
    |> String.trim()
    |> String.replace(~r/\n\s*\n+/, "\n")
  end

  # ---------------------------------------------------------------------------
  # Node tabs (live)
  # ---------------------------------------------------------------------------

  attr :active_nodes, :map, required: true
  attr :hidden_node_ids, :any, required: true
  attr :current_uuid, :string, default: nil

  def node_tabs(assigns) do
    visible =
      assigns.active_nodes
      |> Enum.reject(fn {id, _} -> MapSet.member?(assigns.hidden_node_ids, id) end)
      |> Enum.sort_by(fn {_, n} -> n.equipment_id || n.pubsub_topic end)

    hidden =
      assigns.active_nodes
      |> Enum.filter(fn {id, _} -> MapSet.member?(assigns.hidden_node_ids, id) end)
      |> Enum.map(fn {_, n} -> n end)

    assigns = assign(assigns, visible: visible, hidden: hidden)

    ~H"""
    <nav id="node-tabs" class="flex flex-wrap items-center gap-2" aria-label="Nodes">
      <div :for={{_id, node} <- @visible} class="group relative">
        <button
          id={"node-tab-" <> node.pubsub_topic}
          phx-click="node-select"
          phx-value-pstopic={node.pubsub_topic}
          title={node_state_label(node.state, node.active)}
          class={[
            "flex min-h-11 items-center gap-2.5 rounded-lg border py-1.5 pr-8 pl-3 text-left transition-colors",
            if(node.uuid == @current_uuid,
              do: "border-primary bg-base-100",
              else: "border-line hover:bg-base-100"
            )
          ]}
        >
          <span class={["size-2.5 shrink-0 rounded-full", node_state_dot(node.state, node.active)]}></span>
          <span class="flex flex-col leading-tight">
            <span class="font-semibold">{display_node_name(node)}</span>
            <span class="font-mono text-[11px] text-muted">{node.pubsub_topic}</span>
          </span>
        </button>
        <button
          phx-click="toggle_hidden"
          phx-value-pstopic={node.pubsub_topic}
          class="absolute top-1/2 right-1.5 -translate-y-1/2 rounded p-1 text-muted opacity-0 transition-opacity group-hover:opacity-100 hover:bg-base-300 focus:opacity-100"
          title="Hide node"
          aria-label={"Hide #{display_node_name(node)}"}
        >
          <.icon name="hero-eye-slash-micro" class="size-4" />
        </button>
      </div>

      <div :if={@hidden != []} class="dropdown">
        <button
          tabindex="0"
          id="hidden-nodes-btn"
          class="flex min-h-11 items-center gap-2 rounded-lg border border-dashed border-line px-3 text-muted hover:bg-base-100"
        >
          <.icon name="hero-eye-slash-micro" class="size-4" /> {length(@hidden)} hidden
        </button>
        <div
          tabindex="0"
          class="dropdown-content z-40 mt-2 flex w-64 flex-col gap-1 rounded-box border border-line bg-base-100 p-2 shadow-xl"
        >
          <div
            :for={node <- @hidden}
            class="flex items-center justify-between gap-2 rounded px-2 py-1 hover:bg-base-200"
          >
            <span class="flex items-center gap-2 truncate">
              <span class={["size-2 rounded-full", node_state_dot(node.state, node.active)]}></span>
              {display_node_name(node)}
            </span>
            <button
              phx-click="toggle_hidden"
              phx-value-pstopic={node.pubsub_topic}
              class="rounded p-1 text-muted hover:bg-base-300"
              title="Show node"
              aria-label={"Show #{display_node_name(node)}"}
            >
              <.icon name="hero-eye-micro" class="size-4" />
            </button>
          </div>
        </div>
      </div>
    </nav>
    """
  end

  defp display_node_name(%{equipment_id: id}) when is_binary(id), do: Util.display_name(id)

  defp display_node_name(%{uuid: uuid}) when is_binary(uuid),
    do: "node " <> String.slice(uuid, 0, 8)

  defp display_node_name(node), do: node.pubsub_topic

  # ---------------------------------------------------------------------------
  # Node header (live and historical)
  # ---------------------------------------------------------------------------

  attr :node, :map, required: true
  attr :state_map, :map, default: nil, doc: "live connection state; nil in the data browser"
  attr :status_counts, :list, default: []
  slot :extra

  def node_header(assigns) do
    ~H"""
    <section
      id="node-header"
      class="flex flex-wrap items-center gap-x-8 gap-y-3 rounded-box border border-line bg-base-100 px-4 py-3"
    >
      <div class="min-w-0 max-w-[36rem] flex-[0_1_auto]">
        <div class="flex flex-wrap items-center gap-2.5">
          <h1 class="text-xl font-bold tracking-tight">{Util.display_name(@node.equipment_id)}</h1>
          <.check_badge check_result={@node.check_result} />
          {render_slot(@extra)}
        </div>
        <p
          :if={@node.description}
          class="mt-0.5 line-clamp-2 whitespace-pre-line text-muted"
          title={@node.description}
        >
          {compact_text(@node.description)}
        </p>
        <div
          :if={@status_counts != []}
          class="mt-1.5 flex flex-wrap gap-x-4 gap-y-1 text-xs"
          id="status-summary"
        >
          <span :for={{label, class} <- @status_counts} class="inline-flex items-center gap-1.5">
            <span class={["size-2 rounded-full", class]}></span>{label}
          </span>
        </div>
      </div>

      <dl class="grid grid-cols-[auto_auto] gap-x-3 gap-y-0.5 border-line text-xs sm:border-l sm:pl-8">
        <dt class="text-muted">URI</dt>
        <dd class="font-mono">{node_id_str(@node)}</dd>
        <dt class="text-muted">UUID</dt>
        <dd
          class="cursor-pointer font-mono"
          id={"uuid-" <> to_string(@node.uuid)}
          phx-hook="CopyToClipboard"
          data-copy={@node.uuid}
          data-tip={@node.uuid}
          title="Click to copy"
        >
          {String.slice(to_string(@node.uuid), 0, 8)}…
        </dd>
      </dl>
      <dl class="grid grid-cols-[auto_auto] gap-x-3 gap-y-0.5 text-xs">
        <dt :if={@node.firmware} class="text-muted">Firmware</dt>
        <dd :if={@node.firmware}>{@node.firmware}</dd>
        <dt class="text-muted">{if @state_map, do: "Connected", else: "Recorded"}</dt>
        <dd>
          {@node.inserted_at
          |> DateTime.from_naive!("Etc/UTC")
          |> DateTime.shift_zone!("Europe/Berlin")
          |> Calendar.strftime("%d.%m.%Y %H:%M")}
        </dd>
      </dl>

      <div class="flex flex-wrap items-center gap-2">
        <button
          :if={@state_map}
          id="live-updates-toggle"
          phx-click="toggle-conn-state"
          aria-pressed={to_string(@state_map.active)}
          class="btn btn-sm gap-2 border-line bg-transparent font-normal"
          title="Asynchronous update messages from the node"
        >
          <span class={[
            "relative inline-block h-3.5 w-6 rounded-full transition-colors",
            if(@state_map.active, do: "bg-st-idle", else: "bg-st-off")
          ]}>
            <span class={[
              "absolute top-0.5 size-2.5 rounded-full bg-base-100 transition-all",
              if(@state_map.active, do: "right-0.5", else: "left-0.5")
            ]}></span>
          </span>
          {if @state_map.active, do: "Live updates", else: "Updates paused"}
        </button>
        <a
          :if={@node.ophyd_class}
          href={"data:text/x-python;base64,#{Base.encode64(@node.ophyd_class)}"}
          download={Util.display_name(@node.equipment_id) <> "_" <> String.slice(to_string(@node.uuid), 0, 8) <> ".py"}
          class="btn btn-sm border-line bg-transparent font-normal"
        >
          <.icon name="hero-arrow-down-tray-micro" class="size-4" /> ophyd class
        </a>
      </div>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Module rail (live and historical)
  # ---------------------------------------------------------------------------

  attr :node, :map, required: true
  attr :selected, :string, default: nil
  attr :mode, :atom, default: :live
  attr :node_state, :atom, default: :initialized

  def module_rail(assigns) do
    assigns =
      assigns
      |> assign(:groups, group_modules(assigns.node.modules))
      |> assign(:node_id_str, node_id_str(assigns.node))

    ~H"""
    <aside
      id="module-rail"
      class="sticky top-[4.25rem] max-h-[calc(100vh-5.5rem)] w-full overflow-y-auto rounded-box border border-line bg-base-100 p-2 lg:w-60 lg:shrink-0"
      aria-label="Modules"
    >
      <div class="px-1.5 pt-1 pb-1 text-[11px] font-semibold tracking-wider text-muted uppercase">
        Modules · {length(@node.modules)}
      </div>
      <div :for={{label, modules} <- @groups} class="mt-2">
        <div :if={label} class="px-1.5 pb-1 text-[11px] text-muted">{label}</div>
        <button
          :for={module <- modules}
          id={"rail-" <> module.name}
          phx-click="select_module"
          phx-value-module={module.name}
          aria-current={if(module.name == @selected, do: "true")}
          class={[
            "flex min-h-8 w-full items-center gap-2 rounded-md px-1.5 py-1 text-left transition-colors",
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
            <span class="shrink-0 font-mono text-[10px] text-muted">
              {class_label(module.highest_interface_class)}
            </span>
          <% end %>
        </button>
      </div>
    </aside>
    """
  end

  # ---------------------------------------------------------------------------
  # Card grid (live)
  # ---------------------------------------------------------------------------

  attr :node, :map, required: true
  attr :selected, :string, default: nil

  def module_grid(assigns) do
    assigns = assign(assigns, :groups, group_modules(assigns.node.modules))

    ~H"""
    <div id="module-grid" class="flex min-w-0 flex-col gap-5">
      <section :for={{label, modules} <- @groups}>
        <h2 class="mb-2 text-[11px] font-semibold tracking-wider text-muted uppercase">
          {label || "Modules"} <span class="font-normal">· {length(modules)}</span>
        </h2>
        <div class="grid grid-cols-[repeat(auto-fill,minmax(240px,1fr))] gap-2.5">
          <.module_card
            :for={module <- modules}
            module={module}
            node={@node}
            selected={module.name == @selected}
          />
        </div>
      </section>
    </div>
    """
  end

  attr :module, :map, required: true
  attr :node, :map, required: true
  attr :selected, :boolean, default: false

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
        "flex min-w-0 flex-col gap-2 rounded-box border bg-base-100 p-3 transition-colors",
        if(@selected, do: "border-primary", else: "border-line")
      ]}
    >
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
          <span class="block font-mono text-[10.5px] text-muted">
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
        node_state={:initialized}
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
        parameter={@value_param}
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
          class="rounded px-1 py-0.5 text-[11.5px] text-muted hover:bg-base-200 hover:text-base-content"
        >
          {length(@module.parameters)} params<span :if={@other_commands > 0}> · {@other_commands} cmds</span>
          ›
        </button>
      </footer>
    </article>
    """
  end

  # ---------------------------------------------------------------------------
  # Module detail (live inspector and data-browser main panel)
  # ---------------------------------------------------------------------------

  attr :module, :map, required: true
  attr :node, :map, required: true
  attr :mode, :atom, default: :live
  attr :plot_param, :string, default: nil
  attr :plot_id, :string, required: true
  attr :chart_height, :integer, default: 260

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

    ~H"""
    <div class="flex flex-col gap-4" id={"module-detail-" <> @module.name}>
      <header>
        <div class="flex flex-wrap items-center gap-x-2.5 gap-y-1">
          <h2 class="text-lg font-bold tracking-tight">{Util.display_name(@module.name)}</h2>
          <span class="rounded bg-base-300 px-1.5 py-0.5 font-mono text-[10.5px] text-muted">
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
            node_state={:initialized}
            indicator_select={:compact}
          />
        </div>
        <div class="font-mono text-[11px] text-muted">{@node_id_str} · {@module.name}</div>
        <p :if={@module.description} class="mt-1 whitespace-pre-line text-muted">
          {String.trim(@module.description)}
        </p>
      </header>

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
            <div class="font-mono text-[12.5px] font-semibold">{command.name}</div>
            <div :if={command.description} class="text-[11.5px] text-muted">
              {command.description}
            </div>
            <div :if={command.datainfo["argument"]} class="font-mono text-[10.5px] text-muted">
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
          <.property prop_key="interface classes" value_class="font-mono text-[11px]">
            {Enum.join(@module.interface_classes || [], ", ")}
          </.property>
          <.property :if={@module.group} prop_key="group">{@module.group}</.property>
          <.property :if={@module.visibility} prop_key="visibility">{@module.visibility}</.property>
          <.property
            :if={@module.implementor}
            prop_key="implementor"
            value_class="font-mono text-[11px] break-all"
          >
            {@module.implementor}
          </.property>
          <.property :if={@module.meaning} prop_key="meaning" value_class="font-mono text-[11px]">
            {Util.short_inspect(@module.meaning)}
          </.property>
          <.custom_properties properties={@module.custom_properties} />
        </dl>
        <details :if={@module_json} class="mt-2 rounded border border-line">
          <summary class="cursor-pointer px-2 py-1 text-xs text-muted hover:bg-base-200">
            Description JSON
          </summary>
          <pre class="max-h-96 overflow-auto border-t border-line bg-base-200 p-2 font-mono text-[11px]">{@module_json}</pre>
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
        <span class="min-w-0 flex-1 font-mono text-[12.5px] font-semibold break-all">
          {@parameter.name}
        </span>
        <span class="font-mono text-[10.5px] text-muted">{@type_label}</span>
        <span :if={@unit != ""} class="font-mono text-[10.5px] text-muted">[{@unit}]</span>
        <span class="rounded border border-line px-1 font-mono text-[10px] text-muted">
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
      <div :if={@parameter.description} class="mt-0.5 text-[11.5px] text-muted">
        {@parameter.description}
      </div>
      <div :if={@limits} class="font-mono text-[10.5px] text-muted">range {@limits}</div>
      <div :if={@enum_members != []} class="mt-1 flex flex-wrap gap-1">
        <span
          :for={{name, code} <- @enum_members}
          class={["rounded border px-1.5 font-mono text-[10.5px]", ValueFormat.enum_class(code)]}
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
      class="sticky top-[4.25rem] flex max-h-[calc(100vh-5.5rem)] w-full shrink-0 overflow-hidden rounded-box border border-line bg-base-100 xl:w-(--inspector-w) xl:max-w-[calc(100vw-34rem)]"
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
end
