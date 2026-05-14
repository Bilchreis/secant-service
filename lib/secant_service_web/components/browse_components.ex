defmodule SecantServiceWeb.BrowseComponents do
  use Phoenix.Component

  alias SecantService.Util
  alias Jason

  import SecantServiceWeb.CoreComponents
  import SecantServiceWeb.SECoPComponents
  alias Phoenix.LiveView.JS

  attr :node, :map, required: true

  def browse_sec_node(assigns) do
    grouped_modules = Enum.group_by(assigns.node.modules, &(&1.group || nil)) |> Enum.sort()

    assigns =
      assign(assigns, :grouped_modules, grouped_modules)
      |> assign(:n_modules, length(assigns.node.modules))

    ~H"""
    <.sec_node node={@node}>
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
                <.browse_module
                  module={module}
                  host={@node.host}
                  port={@node.port}
                  n_modules={@n_modules}
                  interface_class={module.highest_interface_class}
                  module_descr={@node.describe_message["modules"][module.name]}
                />
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </.sec_node>
    """
  end

  attr :enum, :map, required: true

  def enum(assigns) do
    ordered_members = assigns.enum["members"] |> Enum.sort_by(fn {_, v} -> v end)

    assigns =
      assigns
      |> assign(:ordered_members, ordered_members)

    ~H"""
    <div class="space-y-4">
      <!-- Badge View -->
      <div class="card bg-base-200 overflow-hidden mt-2 inline-flex">
        <div class="p-4 flex flex-wrap gap-2">
          <%= for {name, value} <- @ordered_members do %>
            <div class="flex items-center px-3 py-1.5 rounded-md border border-base-100 bg-neutral text-neutral-content ">
              <span class="font-mono text-sm font-medium">{name}</span>
              <span class="ml-2 px-2 py-0.5 rounded-full bg-base-200/70 text-xs font-mono">
                {value}
              </span>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp get_color_class(code) do
    color_classes = %{
      :disabled =>
        "bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-200 border-gray-300 dark:border-gray-600",
      :idle =>
        "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-100 border-green-200 dark:border-green-800",
      :warn =>
        "bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-100 border-yellow-200 dark:border-yellow-800",
      :busy =>
        "bg-orange-100 text-orange-800 dark:bg-orange-900 dark:text-orange-100 border-orange-200 dark:border-orange-800",
      :error =>
        "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-100 border-red-200 dark:border-red-800"
    }

    state =
      cond do
        code < 99 -> :disabled
        code < 199 -> :idle
        code < 299 -> :warn
        code < 399 -> :busy
        code < 499 -> :error
        true -> :disabled
      end

    {state, color_classes[state]}
  end

  attr :status_tuple, :map, required: true

  def status_tuple(assigns) do
    ordered_members =
      assigns.status_tuple["members"]
      |> Enum.at(0)
      |> Map.get("members")
      |> Enum.sort_by(fn {_, v} -> v end)
      |> Enum.map(fn {name, value} ->
        {name, value, get_color_class(value)}
      end)

    assigns =
      assigns
      |> assign(:ordered_members, ordered_members)

    ~H"""
    <div class="">
      <!-- Badge View -->
      <div class="bg-white dark:bg-gray-800 rounded-lg border border-gray-200 dark:border-gray-700 overflow-hidden mt-2 inline-flex">
        <div class="p-4 flex flex-wrap gap-2">
          <%= for {name, value, {_state, color_class}} <- @ordered_members do %>
            <div class={["flex items-center px-3 py-1.5 rounded-md border", color_class]}>
              <span class="font-mono text-sm font-medium">{name}</span>
              <span class="ml-2 px-2 py-0.5 rounded-full bg-white/75 dark:bg-gray-800/75 text-xs font-mono">
                {value}
              </span>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :module, :map, required: true
  attr :host, :string, required: true
  attr :port, :integer, required: true
  attr :n_modules, :integer, default: 0
  attr :interface_class, :string
  attr :module_descr, :map, required: true

  def browse_module(assigns) do
    grouped_parameters =
      Enum.group_by(assigns.module.parameters, &(&1.group || nil)) |> Enum.sort()

    grouped_commands = Enum.group_by(assigns.module.commands, &(&1.group || nil)) |> Enum.sort()

    assigns =
      assigns
      |> assign_new(:node_id_str, fn -> "#{to_string(assigns.host)}:#{assigns.port}" end)
      |> assign(:grouped_parameters, grouped_parameters)
      |> assign(:grouped_commands, grouped_commands)

    ~H"""
    <.base_module
      module={@module}
      host={@host}
      port={@port}
      n_modules={@n_modules}
      interface_class={@interface_class}
      node_id_str={@node_id_str}
      plot_mode={:historical}
    >
      <:parameter_preview></:parameter_preview>

      <:command_preview></:command_preview>

      <:parameter_details>
        <%= for {group_name, parameters} <- @grouped_parameters do %>
          <%= if group_name == nil do %>
            <div class="mt-4 border-l-4 border-transparent pl-4">
              <%= for parameter <- parameters do %>
                <.parameter
                  parameter={parameter}
                  parameter_descr={@module_descr["accessibles"][parameter.name]}
                />
              <% end %>
            </div>
          <% else %>
            <div class="mt-4 border-l-4 border-gray-500 pl-4">
              <h4 class="text-xl font-semibold mb-2 text-gray-800 dark:text-white">
                {Util.display_name(group_name)}
              </h4>
              <%= for parameter <- parameters do %>
                <.parameter
                  parameter={parameter}
                  parameter_descr={@module_descr["accessibles"][parameter.name]}
                />
              <% end %>
            </div>
          <% end %>
        <% end %>
      </:parameter_details>

      <:command_details>
        <%= for {group_name, commands} <- @grouped_commands do %>
          <%= if group_name == nil do %>
            <div class="mt-4 border-l-4 border-transparent pl-4">
              <%= for command <- commands do %>
                <.command
                  command={command}
                  command_descr={@module_descr["accessibles"][command.name]}
                />
              <% end %>
            </div>
          <% else %>
            <div class="mt-4 border-l-4 border-gray-500 pl-4">
              <h4 class="text-xl font-semibold mb-2 text-gray-800 dark:text-white">
                {Util.display_name(group_name)}
              </h4>
              <%= for command <- commands do %>
                <.command
                  command={command}
                  command_descr={@module_descr["accessibles"][command.name]}
                />
              <% end %>
            </div>
          <% end %>
        <% end %>
      </:command_details>
    </.base_module>
    """
  end

  attr :parameter, :map, required: true
  attr :parameter_descr, :map, required: true

  def parameter(assigns) do
    parameter_pretty = Jason.encode!(assigns.parameter_descr, pretty: true)

    assigns =
      assigns
      |> assign(:parameter_pretty, parameter_pretty)

    ~H"""
    <!-- Parameter Name -->
    <div class="card mb-4 bg-neutral p-4 shadow-md">
      <div class="flex justify-between">
        <div class="text-lg font-bold text-neutral-content">
          {Util.display_name(@parameter.name)}:
        </div>
        <div class="flex text-sm text-base-content pt-1 gap-2">
          <div class="px-2 py-0.5 rounded-full bg-base-100 font-mono">
            {@parameter.datainfo["type"]}
          </div>
          <%= if @parameter.readonly do %>
            <div class="px-2 py-0.5 rounded-full bg-base-100 font-mono">
              r
            </div>
          <% else %>
            <div class="px-2 py-0.5 rounded-full bg-base-100 font-mono">
              r/w
            </div>
          <% end %>
          <button
            class="btn btn-warning btn-sm"
            phx-click={
              JS.push("show_parameter_graph", value: %{parameter_id: to_string(@parameter.id)})
            }
          >
            <div class="flex items-center">
              <.icon name="hero-chart-bar-solid" class="h-5 w-5 flex-none mr-1" /> Graph
            </div>
          </button>
        </div>
      </div>
      <ul class="mt-2 text-sm text-neutral-content/80">
        <!-- Description -->
        <.property
          prop_key="Description"
          class=""
          key_class="text-neutral-content/80 text-sm font-bold"
        >
          {@parameter.description}
        </.property>
        
    <!-- Readonly -->
        <.property prop_key="Readonly" key_class="text-neutral-content/80 font-semibold">
          {@parameter.readonly}
        </.property>
        
    <!-- Optional Properties -->
        <%= if @parameter.group do %>
          <.property prop_key="Group" key_class="text-neutral-content/80 font-semibold"></.property>
        <% end %>

        <%= if @parameter.visibility do %>
          <.property prop_key="Visibility" key_class="text-neutral-content/80 font-semibold">
            {@parameter.visibility}
          </.property>
        <% end %>

        <%= if @parameter.meaning do %>
          <.property prop_key="Meaning" key_class="text-neutral-content/80 font-semibold">
            {inspect(@parameter.meaning)}
          </.property>
        <% end %>

        <%= if @parameter.checkable do %>
          <.property prop_key="Checkable" key_class="text-neutral-content/80 font-semibold">
            {@parameter.checkable}
          </.property>
        <% end %>

        <%= if @parameter.datainfo["type"] == "enum" do %>
          <.property
            prop_key="Enum Members"
            key_class="text-neutral-content/80 font-semibold"
          >
            > <.enum enum={@parameter.datainfo} />
          </.property>
        <% end %>
        
    <!-- Custom Properties -->
        <%= for {property_name, property_value} <- @parameter.custom_properties do %>
          <.property
            prop_key={String.replace_prefix(property_name, "_", "")}
            key_class="text-neutral-content/80 font-semibold"
          >
            > {inspect(property_value)}
          </.property>
        <% end %>

        <%= if @parameter.name == "status" do %>
          <.status_tuple status_tuple={@parameter.datainfo} />
        <% end %>
      </ul>
      
    <!-- Datainfo -->
      <.datainfo_collapsible datainfo={@parameter_pretty} />
    </div>
    """
  end

  attr :command, :map, required: true
  attr :command_descr, :map, required: true

  def command(assigns) do
    datainfo_pretty = Jason.encode!(assigns.command.datainfo, pretty: true)

    assigns =
      assigns
      |> assign(:datainfo_pretty, datainfo_pretty)

    ~H"""
    <div class="card mb-4 bg-neutral p-4 shadow-md">
      
    <!-- Parameter Name -->
      <div>
        <span class="text-lg font-bold text-neutral-content">
          {Util.display_name(@command.name)}:
        </span>
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
      
    <!-- Datainfo -->
      <.datainfo_collapsible datainfo={@datainfo_pretty} />
    </div>
    """
  end

  attr :datainfo, :string, required: true

  def datainfo_collapsible(assigns) do
    ~H"""
    <div class="mt-2 collapse collapse-arrow bg-base-100 border-base-300 border ">
      <input type="checkbox" />

      <div class="collapse-title font-semibold">
        <div class="flex p-2">
          <.icon name="hero-information-circle" class=" h-5 w-5  mr-1" />
          <div>JSON Description:</div>
        </div>
      </div>
      <div class="collapse-content text-sm">
        <pre class="card bg-base-200 text-base-content whitespace-pre-wrap break-words max-h-[60vh] overflow-y-auto font-mono text-xs p-2 ">{@datainfo}</pre>
      </div>
    </div>
    """
  end
end
