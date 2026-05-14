defmodule SecantServiceWeb.DashboardComponents do
  use Phoenix.Component

  alias SecantService.SecNodes.Module

  alias SecantService.Util
  alias Jason
  alias SecantServiceWeb.Components.ModuleIndicator
  alias SecantServiceWeb.Components.ParameterValueDisplay
  alias SecantServiceWeb.Components.CommandDisplay

  import SecantServiceWeb.SECoPComponents
  import SecantServiceWeb.Components.ParameterFormFieldComponents
  import SecantServiceWeb.CoreComponents
  alias Phoenix.LiveView.JS

  defp sort_commands_with_priority(commands) do
    priority_order = [
      "stop",
      "go",
      "reset",
      "clear_errors",
      "control_off",
      "communicate",
      "hold",
      "prepare",
      "shutdown",
      "get_data"
    ]

    {priority_commands, other_commands} =
      Enum.split_with(commands, fn cmd -> cmd.name in priority_order end)

    sorted_priority =
      Enum.sort_by(priority_commands, fn cmd ->
        Enum.find_index(priority_order, &(&1 == cmd.name)) || 999
      end)

    sorted_priority ++ Enum.sort_by(other_commands, & &1.name)
  end

  attr :node, :map, required: true
  attr :state_map, :map, required: true

  slot :inner_block

  def dash_sec_node(assigns) do
    grouped_modules = Enum.group_by(assigns.node.modules, &(&1.group || nil)) |> Enum.sort()

    assigns =
      assign(assigns, :grouped_modules, grouped_modules)
      |> assign(:n_modules, length(assigns.node.modules))

    ~H"""
    <.sec_node node={@node} state_map={@state_map}>
      <!--Modules -->
      <div class="mt-3 card  ">
        <%= for {group_name, modules} <- @grouped_modules do %>
          <div class="collapse  collapse-arrow bg-base-100 border-base-300 border">
            <input
              type="checkbox"
              checked
            />
            <div class="collapse-title font-semibold">
              <%= if group_name == nil do %>
                Ungrouped Modules
              <% else %>
                {Util.display_name(group_name)}
              <% end %>
            </div>
            <div class="collapse-content text-sm">
              <%= for module <- modules do %>
                <.dash_module
                  module={module}
                  host={@node.host}
                  port={@node.port}
                  n_modules={@n_modules}
                  interface_class={module.highest_interface_class}
                />
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </.sec_node>
    """
  end

  attr :node, :map, required: true
  attr :node_state, :atom, required: true
  attr :values, :map, required: true
  attr :node_id_str, :string, required: true

  def module_indicators(assigns) do
    assigns =
      assign_new(assigns, :node_id_str, fn ->
        "#{to_string(assigns.node.host)}:#{assigns.node.port}"
      end)

    ~H"""
    <div class="flex-none p-3 card bg-base-200 max-h-screen overflow-y-auto  ">
      <span class="text-base-content text-lg font-bold">Module Status:</span>
      <ul class="mt-1 space-y space-y-2">
        <%= for module <- @node.modules do %>
          <li class=" flex-1 min-w-full">
            <.live_component
              module={ModuleIndicator}
              id={"module_indicator:" <> @node_id_str <>":" <> module.name}
              host={@node.host}
              port={@node.port}
              module_name={module.name}
              highest_if_class={module.highest_interface_class}
              status_param={Module.get_parameter(module, "status")}
              node_state={@node_state}
              indicator_select={:outer}
            />
          </li>
        <% end %>
      </ul>
    </div>
    """
  end

  attr :module, :map, required: true
  attr :host, :string, required: true
  attr :port, :integer, required: true
  attr :n_modules, :integer, default: 0
  attr :status, :boolean, default: false

  attr :interface_class, :string
  attr :node_id_str, :string, required: true

  slot :parameter_preview

  def dash_base_module(assigns) do
    grouped_parameters =
      Enum.group_by(assigns.module.parameters, &(&1.group || nil)) |> Enum.sort()

    grouped_commands = Enum.group_by(assigns.module.commands, &(&1.group || nil)) |> Enum.sort()

    assigns =
      assigns
      |> assign(:grouped_parameters, grouped_parameters)
      |> assign(:grouped_commands, grouped_commands)
      |> assign(:sorted_commands, sort_commands_with_priority(assigns.module.commands))

    ~H"""
    <.base_module
      module={@module}
      host={@host}
      port={@port}
      n_modules={@n_modules}
      status={@status}
      interface_class={@interface_class}
      node_id_str={@node_id_str}
      plot_mode={:live}
    >
      <:parameter_preview>
        {render_slot(@parameter_preview)}
      </:parameter_preview>

      <:command_preview>
        <div :if={@module.commands != []} class="flex rounded-lg gap-2 mt-2 p-2 bg-neutral/40">
          <%= for command <- @sorted_commands do %>
            <.live_component
              module={CommandDisplay}
              id={"module_dash:"<> @node_id_str <> ":" <> @module.name <> ":" <> command.name}
              class=""
              host={@host}
              port={@port}
              location="module_dash"
              module_name={@module.name}
              command={command}
              id_str={"module_dash:"<> @node_id_str <> ":" <> @module.name <> ":" <> command.name}
            />
          <% end %>
        </div>
      </:command_preview>

      <:parameter_details>
        <%= for {group_name, parameters} <- @grouped_parameters do %>
          <div class="collapse collapse-arrow bg-base-100 border-base-300 border">
            <%= if group_name == nil do %>
              <input type="checkbox" checked />
            <% else %>
              <input type="checkbox" />
            <% end %>
            <div class="collapse-title font-semibold">
              <%= if group_name == nil do %>
                Ungrouped Parameters
              <% else %>
                {Util.display_name(group_name)}
              <% end %>
            </div>
            <div class="collapse-content text-sm">
              <%= for parameter <- parameters do %>
                <.live_component
                  module={SecantServiceWeb.Components.DashParameter}
                  id={"dash_parameter:" <> @node_id_str <> ":" <> @module.name <> ":" <> parameter.name}
                  host={@host}
                  port={@port}
                  node_id_str={@node_id_str}
                  module_name={@module.name}
                  parameter={parameter}
                />
              <% end %>
            </div>
          </div>
        <% end %>
      </:parameter_details>

      <:command_details>
        <div :if={@module.commands != []} class="card border-4 bg-base-200 border-base-100 p-4 mt-4">
          <h3 class="text-lg font-bold text-base-content mb-2">Commands:</h3>
          <%= for {group_name, commands} <- @grouped_commands do %>
            <div class="collapse collapse-arrow bg-base-100 border-base-300 border ">
              <%= if group_name == nil do %>
                <input type="checkbox" checked />
              <% else %>
                <input type="checkbox" />
              <% end %>
              <div class="collapse-title font-semibold">
                <%= if group_name == nil do %>
                  Ungrouped Commands
                <% else %>
                  {Util.display_name(group_name)}
                <% end %>
              </div>
              <div class="collapse-content text-sm ">
                <%= for command <- commands do %>
                  <.dash_command command={command} />
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </:command_details>
    </.base_module>
    """
  end

  attr :module, :map, required: true
  attr :host, :string, required: true
  attr :port, :integer, required: true
  attr :n_modules, :integer, default: 0
  attr :interface_class, :string

  def dash_module(%{interface_class: "communicator"} = assigns) do
    assigns =
      assigns
      |> assign_new(:node_id_str, fn -> "#{to_string(assigns.host)}:#{assigns.port}" end)
      |> assign(:status, Module.has_status?(assigns.module))

    ~H"""
    <.dash_base_module
      module={@module}
      host={@host}
      port={@port}
      n_modules={@n_modules}
      interface_class={@interface_class}
      node_id_str={@node_id_str}
      status={@status}
    >
      <:parameter_preview>
        <div></div>
      </:parameter_preview>
    </.dash_base_module>
    """
  end

  def dash_module(%{interface_class: "readable"} = assigns) do
    assigns =
      assigns
      |> assign_new(:node_id_str, fn -> "#{to_string(assigns.host)}:#{assigns.port}" end)
      |> assign(:status, Module.has_status?(assigns.module))

    ~H"""
    <.dash_base_module
      module={@module}
      host={@host}
      port={@port}
      n_modules={@n_modules}
      interface_class={@interface_class}
      node_id_str={@node_id_str}
      status={@status}
    >
      <:parameter_preview>
        <div class="grid grid-cols-[auto_1fr] items-center mt-4">
          <div class="p-2 text-lg font-bold text-neutral-content">
            Value:
          </div>
          <.live_component
            module={ParameterValueDisplay}
            id={"module_dash:"<> @node_id_str <> ":" <> @module.name <> ":value"}
            class=""
            host={@host}
            port={@port}
            location="module_dash"
            module_name={@module.name}
            parameter={Module.get_parameter(@module, "value")}
            id_str={"module_dash:"<> @node_id_str <> ":" <> @module.name <> ":value"}
          />
        </div>
      </:parameter_preview>
    </.dash_base_module>
    """
  end

  def dash_module(%{interface_class: interface_class} = assigns)
      when interface_class in ["writable", "drivable", "calibratable"] do
    assigns =
      assigns
      |> assign_new(:node_id_str, fn -> "#{to_string(assigns.host)}:#{assigns.port}" end)
      |> assign(:status, Module.has_status?(assigns.module))

    ~H"""
    <.dash_base_module
      module={@module}
      host={@host}
      port={@port}
      n_modules={@n_modules}
      interface_class={@interface_class}
      node_id_str={@node_id_str}
      status={@status}
    >
      <:parameter_preview>
        <div class="grid grid-cols-[auto_1fr] items-center mt-4">
          <div class="p-2 text-lg font-bold text-neutral-content">
            Value:
          </div>
          <.live_component
            module={ParameterValueDisplay}
            id={"module_dash:"<> @node_id_str <>":" <> @module.name <> ":value"}
            class=""
            host={@host}
            port={@port}
            location="module_dash"
            module_name={@module.name}
            parameter={Module.get_parameter(@module, "value")}
            id_str={"module_dash:"<> @node_id_str <> ":" <> @module.name <> ":value"}
          />

          <div class="p-2 mt-2 text-lg font-bold text-neutral-content">
            Target:
          </div>
          <.live_component
            module={ParameterValueDisplay}
            id={"module_dash:"<> @node_id_str <>":" <> @module.name <> ":target"}
            class=""
            host={@host}
            port={@port}
            module_name={@module.name}
            location="module_dash"
            parameter={Module.get_parameter(@module, "target")}
            id_str={"module_dash:"<> @node_id_str <> ":" <> @module.name <> ":target"}
          />
        </div>
      </:parameter_preview>
    </.dash_base_module>
    """
  end

  def dash_module(%{interface_class: "acquisition"} = assigns) do
    assigns =
      assigns
      |> assign_new(:node_id_str, fn -> "#{to_string(assigns.host)}:#{assigns.port}" end)
      |> assign(:status, Module.has_status?(assigns.module))

    ~H"""
    <.dash_base_module
      module={@module}
      host={@host}
      port={@port}
      n_modules={@n_modules}
      interface_class={@interface_class}
      node_id_str={@node_id_str}
      status={@status}
    >
      <:parameter_preview>
        <div class="grid grid-cols-[auto_1fr] items-center mt-4">
          <div class="p-2 text-lg font-bold text-neutral-content">
            Value:
          </div>
          <.live_component
            module={ParameterValueDisplay}
            id={"module_dash:"<> @node_id_str <> ":" <> @module.name <> ":value"}
            class=""
            host={@host}
            port={@port}
            location="module_dash"
            module_name={@module.name}
            parameter={Module.get_parameter(@module, "value")}
            id_str={"module_dash:"<> @node_id_str <> ":" <> @module.name <> ":value"}
          />
        </div>
      </:parameter_preview>
    </.dash_base_module>
    """
  end

  def dash_module(%{interface_class: "acquisition_channel"} = assigns) do
    assigns =
      assigns
      |> assign_new(:node_id_str, fn -> "#{to_string(assigns.host)}:#{assigns.port}" end)
      |> assign(:status, Module.has_status?(assigns.module))

    ~H"""
    <.dash_base_module
      module={@module}
      host={@host}
      port={@port}
      n_modules={@n_modules}
      interface_class={@interface_class}
      node_id_str={@node_id_str}
      status={@status}
    >
      <:parameter_preview>
        <div class="grid grid-cols-[auto_1fr] items-center mt-4">
          <div class="p-2 text-lg font-bold text-neutral-content">
            Value:
          </div>
          <.live_component
            module={ParameterValueDisplay}
            id={"module_dash:"<> @node_id_str <> ":" <> @module.name <> ":value"}
            class=""
            host={@host}
            port={@port}
            location="module_dash"
            module_name={@module.name}
            parameter={Module.get_parameter(@module, "value")}
            id_str={"module_dash:"<> @node_id_str <> ":" <> @module.name <> ":value"}
          />
        </div>
      </:parameter_preview>
    </.dash_base_module>
    """
  end

  def dash_module(%{interface_class: "acquisition_controller"} = assigns) do
    assigns =
      assigns
      |> assign_new(:node_id_str, fn -> "#{to_string(assigns.host)}:#{assigns.port}" end)
      |> assign(:status, Module.has_status?(assigns.module))

    ~H"""
    <.dash_base_module
      module={@module}
      host={@host}
      port={@port}
      n_modules={@n_modules}
      interface_class={@interface_class}
      node_id_str={@node_id_str}
      status={@status}
    >
      <:parameter_preview>
        <div></div>
      </:parameter_preview>
    </.dash_base_module>
    """
  end

  attr :command, :map, required: true

  def dash_command(assigns) do
    ~H"""
    <div class="card mb-4 bg-neutral p-4 shadow-md">
      
    <!-- Parameter Name -->
      <div>
        <div class="flex ">
          <div>
            <.datainfo_tooltip datainfo={@command.datainfo} position="tooltip-right" />
          </div>

          <div class="text-lg font-bold text-neutral-content">
            {Util.display_name(@command.name)}:
          </div>
        </div>
        <ul class="mt-2 text-sm text-neutral-content/80">
          <!-- Description -->
          <.property
            prop_key="Description"
            class="card bg-neutral-content/20 mb-2 p-2"
            key_class="text-neutral-content text-sm font-bold"
          >
            {@command.description}
          </.property>
          
    <!-- Optional Properties -->
          <%= if @command.group do %>
            <.property prop_key="Group" key_class="text-neutral-content font-semibold">
              {@command.group}
            </.property>
          <% end %>

          <%= if @command.visibility do %>
            <.property
              prop_key="Visibility"
              key_class="text-neutral-content font-semibold"
            >
              {@command.visibility}
            </.property>
          <% end %>

          <%= if @command.meaning do %>
            <.property prop_key="Meaning" key_class="text-neutral-content font-semibold">
              {inspect(@command.meaning)}
            </.property>
          <% end %>

          <%= if @command.checkable do %>
            <.property prop_key="Checkable" key_class="text-neutral-content font-semibold">
              {@command.checkable}
            </.property>
          <% end %>
          
    <!-- Custom Properties -->
          <%= for {property_name, property_value} <- @command.custom_properties || %{} do %>
            <.property
              prop_key={String.replace_prefix(property_name, "_", "")}
              key_class="text-neutral-content font-semibold"
            >
              {inspect(property_value)}
            </.property>
          <% end %>
        </ul>
      </div>
    </div>
    """
  end
end
