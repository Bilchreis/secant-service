defmodule SecantServiceWeb.SECoPComponents do
  use Phoenix.Component

  alias SecantService.SecNodes.Module
  alias Jason
  alias SecantService.Util
  import SecantServiceWeb.CoreComponents
  alias SecantServiceWeb.Components.ModuleIndicator
  alias Phoenix.LiveView.JS

  # Helper function to get class-specific styles
  def status_to_color(status) do
    case status do
      :disabled -> "bg-gray-500"
      :idle -> "bg-success"
      :warning -> "bg-info"
      :busy -> "bg-warning"
      :error -> "bg-error"
      :unknown -> "bg-white"
    end
  end

  def get_class_styles(interface_class) do
    case interface_class do
      "communicator" ->
        %{
          border: "border-blue-500 dark:border-blue-600/40",
          bg:
            "bg-gradient-to-r from-blue-200 to-blue-300 dark:from-blue-900/30 dark:to-blue-900/40",
          header_bg: "bg-blue-300 dark:bg-blue-800/50",
          icon: "hero-chat-bubble-left-right"
        }

      "readable" ->
        %{
          border: "border-green-500 dark:border-green-600/40",
          bg:
            "bg-gradient-to-r from-green-200 to-green-300 dark:from-green-900/30 dark:to-green-900/40",
          header_bg: "bg-green-300 dark:bg-green-800/50",
          icon: "hero-eye"
        }

      "writable" ->
        %{
          border: "border-amber-500 dark:border-amber-600/40",
          bg:
            "bg-gradient-to-r from-amber-200 to-amber-300 dark:from-amber-900/30 dark:to-amber-900/40",
          header_bg: "bg-amber-300 dark:bg-amber-800/50",
          icon: "hero-pencil-square"
        }

      "drivable" ->
        %{
          border: "border-purple-500 dark:border-purple-600/40",
          bg:
            "bg-gradient-to-r from-purple-200 to-purple-300 dark:from-purple-900/30 dark:to-purple-900/40",
          header_bg: "bg-purple-300 dark:bg-purple-800/50",
          icon: "hero-cog"
        }

      "calibratable" ->
        %{
          border: "border-indigo-500 dark:border-indigo-600/40",
          bg:
            "bg-gradient-to-r from-indigo-200 to-indigo-300 dark:from-indigo-900/30 dark:to-indigo-900/40",
          header_bg: "bg-indigo-300 dark:bg-indigo-800/50",
          icon: "hero-wrench"
        }

      "acquisition" ->
        %{
          border: "border-blue-500 dark:border-blue-600/40",
          bg:
            "bg-gradient-to-r from-blue-200 to-blue-300 dark:from-blue-900/30 dark:to-blue-900/40",
          header_bg: "bg-blue-300 dark:bg-blue-800/50",
          icon: "hero-clock"
        }

      _ ->
        %{
          border: "border-gray-500 dark:border-gray-600/40",
          bg: "bg-gray-200 dark:bg-gray-800/50",
          header_bg: "bg-gray-300 dark:bg-gray-700/50",
          icon: "hero-cube"
        }
    end
  end

  attr :equipment_id, :string, required: true
  attr :pubsub_topic, :string, required: true
  attr :uuid, :string, required: true
  attr :current, :boolean, default: false
  attr :state, :atom, required: true
  attr :connstate, :boolean, required: true

  def node_button(assigns) do
    assigns = assign(assigns, :border_col, state_to_col(assigns.state))

    display_name =
      if assigns.equipment_id != nil do
        Util.display_name(assigns.equipment_id)
      else
        "node: " <> String.slice(assigns.uuid, 0, 8)
      end

    assigns = assign(assigns, :display_name, display_name)

    assigns =
      case assigns.current do
        true -> assign(assigns, :button_col, "bg-primary hover:bg-primary/80")
        false -> assign(assigns, :button_col, "bg-neutral hover:bg-neutral/80")
      end

    ~H"""
    <div class="relative group">
      <button
        phx-click="node-select"
        phx-value-pstopic={@pubsub_topic}
        class={[
          @button_col,
          @border_col,
          "min-w-[240px] border-4 text-neutral-content text-left font-bold py-2 px-4 rounded",
          "font-mono"
        ]}
      >
        <div class="text-xl font-sans">{@display_name}</div>
        <div class="text-sm text-neutral-content/80 opacity-60">{@pubsub_topic}</div>
        <div class="flex gap-2">
          <div class="px-2 py-0.5 rounded-full text-base-content bg-base-200/80 font-mono">
            {@state}
          </div>
          <div class="px-2 py-0.5 rounded-full text-base-content bg-base-200/80 font-mono">
            <%= if @connstate do %>
              <span class="text-success">active </span>
            <% else %>
              <span class="text-warning">inactive</span>
            <% end %>
          </div>
        </div>
      </button>
      <button
        phx-click="toggle_hidden"
        phx-value-pstopic={@pubsub_topic}
        class="absolute top-1 right-1 btn btn-ghost btn-xs btn-circle opacity-0 group-hover:opacity-100 transition-opacity"
        title="Hide node"
      >
        <.icon name="hero-eye-slash" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  attr :equipment_id, :string, required: true
  attr :pubsub_topic, :string, required: true
  attr :uuid, :string, required: true

  def hidden_node_row(assigns) do
    display_name =
      if assigns.equipment_id != nil do
        Util.display_name(assigns.equipment_id)
      else
        "node: " <> String.slice(assigns.uuid, 0, 8)
      end

    assigns = assign(assigns, :display_name, display_name)

    ~H"""
    <div class="flex items-center justify-between gap-2 bg-base-200 rounded px-2 py-1">
      <span class="truncate text-sm">{@display_name}</span>
      <button
        phx-click="toggle_hidden"
        phx-value-pstopic={@pubsub_topic}
        class="btn btn-ghost btn-xs btn-circle"
        title="Show node"
      >
        <.icon name="hero-eye" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  defp state_to_col(state) do
    col =
      case state do
        :connected -> "border-warning"
        :disconnected -> "border-error"
        :initialized -> "border-success"
        _ -> "border-gray-500"
      end

    col
  end

  defp severity_rank(severity) do
    case severity do
      "FATAL" -> 5
      "CATASTROPHIC" -> 4
      "ERROR" -> 3
      "WARNING" -> 2
      "HINT" -> 1
      "PASS" -> 0
      _ -> 5
    end
  end

  defp severity_badge_class(severity) do
    case severity do
      "FATAL" -> "badge-error"
      "CATASTROPHIC" -> "badge-error"
      "ERROR" -> "badge-error"
      "WARNING" -> "badge-warning"
      "HINT" -> "badge-info"
      "PASS" -> "badge-success"
      _ -> "badge-neutral"
    end
  end

  attr :check_result, :map, required: true
  attr :equipment_id, :string, required: true

  def node_title(assigns) do
    assigns = assign(assigns, :equipment_id, Util.display_name(assigns.equipment_id))

    check_result = assigns.check_result

    result_list = Map.get(check_result, "result", [])

    assigns =
      if result_list == [] do
        assigns
        |> assign(:highest_error_class, "PASS")
        |> assign(:result_list, [])
        |> assign(:severity_counts, [])
      else
        highest_error_class =
          result_list
          |> Enum.map(fn x -> x["severity"] end)
          |> Enum.max_by(&severity_rank/1)

        severity_counts =
          result_list
          |> Enum.frequencies_by(& &1["severity"])
          |> Enum.sort_by(fn {severity, _count} -> severity_rank(severity) end, :desc)

        new_result_list =
          Enum.map(result_list, fn diag ->
            col =
              case diag["severity"] do
                "FATAL" -> "border-error"
                "CATASTROPHIC" -> "border-error"
                "ERROR" -> "border-error"
                "WARNING" -> "border-warning"
                "HINT" -> "border-info"
                "PASS" -> "border-success"
                _ -> "border-base-100"
              end

            Map.put(diag, :color, col)
          end)

        assigns
        |> assign(:highest_error_class, highest_error_class)
        |> assign(:result_list, new_result_list)
        |> assign(:severity_counts, severity_counts)
      end

    ~H"""
    <div class="dropdown mb-2">
      <div tabindex="0" role="button" class="flex flex-wrap items-center gap-2 cursor-pointer">
        <div class="shrink-0">
          <%= case @highest_error_class do %>
            <% "PASS" -> %>
              <.icon name="hero-check-badge-solid" class="bg-success h-10 w-10" />
            <% "HINT" -> %>
              <.icon name="hero-check-badge-solid" class="bg-info h-10 w-10" />
            <% "WARNING" -> %>
              <.icon name="hero-exclamation-triangle-solid" class="bg-warning h-10 w-10" />
            <% "ERROR" -> %>
              <.icon name="hero-exclamation-circle-solid" class="bg-error h-10 w-10" />
            <% "CATASTROPHIC" -> %>
              <.icon name="hero-exclamation-circle-solid" class="bg-error h-10 w-10" />
            <% "FATAL" -> %>
              <.icon name="hero-exclamation-circle-solid" class="bg-error h-10 w-10" />
            <% _ -> %>
              <.icon name="hero-question-mark-circle-solid" class="bg-base-200 h-10 w-10" />
          <% end %>
        </div>

        <div class="text-primary text-4xl font-bold">
          {Util.display_name(@equipment_id)}
        </div>

        <span
          :for={{severity, count} <- @severity_counts}
          class={["badge shrink-0 whitespace-nowrap", severity_badge_class(severity)]}
        >
          {count} {severity}
        </span>
      </div>
      <div
        tabindex="0"
        class="dropdown-content z-10 bg-base-100 border border-base-300 rounded-box shadow-lg p-3 w-[48rem] max-w-[85vw] max-h-96 overflow-y-auto"
      >
        <div class="mb-2 text-sm">checked against SECoP v{@check_result["version"]}</div>
        <ul :if={@result_list != []} class="text-sm font-medium">
          <li :for={diag <- @result_list} class={["p-1 mb-1 border-4 rounded-lg", diag.color]}>
            {diag["text"]}
          </li>
        </ul>
        <div :if={@result_list == []} class="text-sm">No issues found.</div>
      </div>
    </div>
    """
  end

  attr :parameter, :string, required: true
  attr :parameter_name, :string, required: true

  def old_dash_parameter(assigns) do
    assigns =
      assign(assigns, parse_param_value(assigns[:parameter]))
      |> assign(:unit, Map.get(assigns.parameter.datainfo, :unit))

    ~H"""
    <div class=" flex justify-between items-start   ">
      <div class="mt-4 block w-full rounded-lg text-white text-lg ">
        {@parameter_name}:
      </div>
    </div>
    <div class="flex justify-between items-start  ">
      <div class="mt-4 block w-full rounded-lg text-white text-lg ">
        {@string_value} {@unit}
      </div>
    </div>
    <%= if @parameter.readonly do %>
      <div class="flex justify-between items-start "></div>
    <% else %>
      <div class="flex justify-between items-start">
        <.form
          for={@parameter.set_form}
          phx-submit="set_parameter"
          phx-change="validate_parameter"
          class="flex space-x-2"
        >
          <input
            type="hidden"
            name="port"
            value={Phoenix.HTML.Form.input_value(@parameter.set_form, :port)}
          />
          <input
            type="hidden"
            name="host"
            value={Phoenix.HTML.Form.input_value(@parameter.set_form, :host)}
          />
          <input
            type="hidden"
            name="module"
            value={Phoenix.HTML.Form.input_value(@parameter.set_form, :module)}
          />
          <input type="hidden" name="parameter" value={@parameter_name} />
          <.input
            name="value"
            type="text"
            field={@parameter.set_form[:value]}
            placeholder="new value"
            phx-debounce="500"
            id={"form:" <> @parameter.parameter_id }
          />
          <button
            type="submit"
            class="mt-2 max-h-11 phx-submit-loading:opacity-75 rounded-lg dark:bg-gray-500 bg-gray-400 hover:bg-gray-600 dark:hover:bg-gray-700   px-3 text-sm font-bold leading-6 text-white active:text-white/80"
          >
            Set
          </button>
        </.form>
      </div>
    <% end %>
    """
  end

  defp parse_param_value(parameter) do
    string_val =
      case parameter.value do
        nil -> %{string_value: "No value"}
        [value | _rest] -> %{string_value: Jason.encode!(value)}
      end

    string_val
  end

  attr :prop_key, :string, required: true
  attr :class, :any
  attr :key_class, :any
  attr :value_class, :any
  slot :inner_block, required: true

  def property(assigns) do
    ~H"""
    <li class={["", assigns[:class]]}>
      <span class={["font-bold", assigns[:key_class]]}>{@prop_key}:</span>
      <span class={["", assigns[:value_class]]}>{render_slot(@inner_block)}</span>
    </li>
    """
  end

  def connect_node(assigns) do
    ~H"""
    <div class="bg-base-200  p-6">
      <div class="flex justify-between items-center mb-4">
        <h3 class="text-xl font-bold text-base-content">Connect to Node</h3>
      </div>

      <form phx-submit="connect-node">
        <fieldset class="fieldset bg-base-200 border-base-300 rounded-box w-xs border p-4">
          <label for="host" class="label">
            Host
          </label>
          <input
            type="text"
            id="host"
            name="host"
            placeholder="localhost"
            required
            class="input"
          />

          <label for="port" class="label">
            Port
          </label>
          <input
            type="number"
            id="port"
            name="port"
            placeholder="8080"
            required
            min="1"
            max="65535"
            class="input"
          />
        </fieldset>
        <div class="flex justify-between mt-2">
          <div class="flex justify-end">
            <button
              type="button"
              phx-click={JS.dispatch("myapp:close-modal")}
              class="mr-2 btn btn-neutral"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="btn btn-primary"
            >
              Connect
            </button>
          </div>
        </div>
      </form>
    </div>
    """
  end

  attr :node, :map, required: true
  attr :state_map, :map, default: nil

  slot :inner_block

  def sec_node(assigns) do
    ~H"""
    <div class="card bg-base-200 flex-1 mt-4 ml-3 p-3  ">
      <div class="card bg-base-100 card-border border-base-300 card-sm p-4 ">
        <div class="grid grid-cols-2 gap-2">
          <div>
            <.node_title check_result={@node.check_result} equipment_id={@node.equipment_id} />

            <div class="grid grid-cols-2 gap-2 mt-2">
              <div class="card bg-neutral text-neutral-content card-sm p-3 overflow-hidden">
                <ul class="text-sm font-medium">
                  <.property
                    prop_key="Description"
                    key_class="text-lg"
                  >
                    <div class="">{@node.display_description}</div>
                  </.property>
                </ul>
              </div>
              <div class="card bg-neutral text-neutral-content card-sm p-3 overflow-hidden">
                <p class="text-lg font-bold ">Node Properties:</p>

                <ul class="text-sm font-medium ">
                  <.property prop_key="Equipment ID">
                    {@node.equipment_id}
                  </.property>

                  <%= if @node.implementor do %>
                    <.property prop_key="Implementor">
                      {@node.implementor}
                    </.property>
                  <% end %>

                  <%= if @node.timeout do %>
                    <.property prop_key="Timeout">
                      {@node.timeout}
                    </.property>
                  <% end %>

                  <%= if @node.firmware do %>
                    <.property prop_key="Firmware">
                      {@node.firmware}
                    </.property>
                  <% end %>

                  <%= for {property_name, property_value} <- @node.custom_properties do %>
                    <.property prop_key={String.replace_prefix(property_name, "_", "")}>
                      {inspect(property_value)}
                    </.property>
                  <% end %>
                </ul>
              </div>
            </div>
          </div>
          <div class="relative text-neutral-base overflow-hidden">
            <ul class="text-lg font-medium text-right">
              <.property prop_key="UUID" value_class="font-mono">
                {@node.uuid}
              </.property>

              <.property prop_key="URI" value_class="font-mono">
                {@node.host <> ":" <> to_string(@node.port)}
              </.property>

              <.property prop_key="Connected at">
                {@node.inserted_at
                |> DateTime.from_naive!("Etc/UTC")
                |> DateTime.shift_zone!("Europe/Berlin")
                |> Calendar.strftime("%d.%m.%Y %H:%M")}
              </.property>
              <.property prop_key="SECoP Version">
                    {@node.secop_version || "v1.0"}
              </.property>



            </ul>

            <fieldset
              :if={@state_map}
              class="absolute right-0 bottom-0  fieldset bg-base-100 border-base-300 rounded-box border p-4"
            >
              <label class="label">
                <input
                  type="checkbox"
                  checked={@state_map.active}
                  phx-click="toggle-conn-state"
                  class="toggle toggle-lg border-warning bg-warning checked:bg-success checked:border-success "
                /> Async update Messages
              </label>
            </fieldset>
          </div>
        </div>

        <a
          :if={@node.ophyd_class}
          href={"data:text/x-python;base64,#{Base.encode64(@node.ophyd_class)}"}
          download={Util.display_name(@node.equipment_id) <> "_" <> String.slice(to_string(@node.uuid), 0, 8) <> ".py"}
          class="mt-2 btn btn-primary w-fit"
        >
          <.icon name="hero-arrow-down-tray" class="h-4 w-4" /> Download ophyd class
        </a>
      </div>

      {render_slot(@inner_block)}
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
  attr :plot_mode, :atom, default: :live

  slot :parameter_preview
  slot :command_preview
  slot :parameter_details
  slot :command_details

  def base_module(assigns) do
    assigns =
      assigns
      |> assign(:styles, get_class_styles(assigns.interface_class))

    ~H"""
    <div class="flex mt-3 items-stretch gap-3">
      <div class="flex-1">
        <%!-- Module header and interactive elements (outside collapse) --%>
        <div class={[
          "bg-base-100 rounded-t-lg p-4",
          @styles.bg,
          @styles.border,
          "border-t-2 border-l-2 border-r-2"
        ]}>
          <%!-- Module Name with Interface Class Icon --%>
          <div class="mb-2 flex items-center">
            <span class="text-2xl font-bold text-gray-800 dark:text-white">
              {Module.display_name(@module)}
            </span>
            <%= if @interface_class do %>
              <span class={[
                "font-bold text-gray-800 dark:text-white text-sm ml-2 px-2 py-1 mb-1 rounded-full",
                @styles.header_bg
              ]}>
                {@interface_class}
              </span>
            <% end %>
          </div>

          <%!-- Module Properties --%>
          <div class="flex">
            <div class="card card-border border-4 border-base-100/80 bg-neutral/45 w-3/4 mr-2 p-3">
              <ul class="text-sm text-neutral-content space-y-2">
                <.property
                  prop_key="Description"
                  key_class="text-lg"
                  value_class="text-lg font-semibold text-neutral-content/80"
                >
                  {@module.description}
                </.property>
                <.property
                  prop_key="Interface Classes"
                  key_class="font-semibold"
                >
                  {@module.interface_classes |> Enum.join(", ")}
                </.property>

                <%= if @module.implementor do %>
                  <.property
                    prop_key="Implementor"
                    key_class="font-semibold"
                  >
                    {@module.implementor}
                  </.property>
                <% end %>

                <%= if @module.meaning do %>
                  <.property
                    prop_key="Meaning"
                    key_class="font-semibold"
                  >
                    {inspect(@module.meaning)}
                  </.property>
                <% end %>

                <%= for {property_name, property_value} <- @module.custom_properties || %{}, property_name != "_plotly" do %>
                  <.property
                    prop_key={String.replace_prefix(property_name, "_", "")}
                    key_class="font-semibold"
                  >
                    {inspect(property_value)}
                  </.property>
                <% end %>
              </ul>
            </div>

            <div
              :if={@status}
              class="w-1/4 card card-border border-4 border-base-100/80 bg-neutral/45 p-3 overflow-hidden"
            >
              <.live_component
                module={ModuleIndicator}
                id={"module_indicator_mod:"<> @node_id_str <>":"<> @module.name}
                host={@host}
                port={@port}
                module_name={@module.name}
                highest_if_class={@module.highest_interface_class}
                status_param={Module.get_parameter(@module, "status")}
                node_state={:initialized}
                indicator_select={:inner}
              />
            </div>
          </div>

          <%!-- Value/Target displays --%>
          {render_slot(@parameter_preview)}

          <%!-- Commands --%>
          {render_slot(@command_preview)}
        </div>
        <%!-- Collapsible section for parameters and commands details --%>
        <div class={[
          "collapse collapse-arrow",
          @styles.bg,
          @styles.border,
          "border-2 rounded-b-lg rounded-t-none "
        ]}>
          <input type="checkbox" />
          <div class="collapse-title text-lg font-semibold text-gray-800 dark:text-white ">
            <.icon name="hero-magnifying-glass" class=" h-5 w-5  mr-1" />
            Configuration Parameters & Details
          </div>
          <div class="collapse-content text-sm">
            <%!-- Parameters --%>
            <div class="card border-4 bg-base-200 border-base-100 p-4 mt-4">
              <h3 class="text-lg font-bold text-base-content mb-2">Parameters:</h3>
              {render_slot(@parameter_details)}
            </div>

            <%!-- Commands --%>

            <div
              :if={@module.commands != []}
              class="card border-4 bg-base-200 border-base-100 p-4 mt-4"
            >
              <h3 class="text-lg font-bold text-base-content mb-2">Commands:</h3>
              {render_slot(@command_details)}
            </div>
          </div>
        </div>
      </div>

      <%= if @n_modules < 20 do %>
        <.live_component
          module={SecantServiceWeb.Components.HistoryDB}
          id={"module-plot:" <> to_string(@module.name)}
          secop_obj={@module}
          plot_mode={@plot_mode}
          class="w-3/5 hidden xl:block"
        />
      <% end %>
    </div>
    """
  end
end
