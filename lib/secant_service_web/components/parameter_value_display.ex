defmodule SecantServiceWeb.Components.ParameterValueDisplay do
  use Phoenix.LiveComponent

  require Logger

  alias SecantService.NodeControl
  alias NodeTable
  import SecantServiceWeb.CoreComponents

  import SecantServiceWeb.Components.ParameterFormFieldComponents
  alias SecantService.NodeValues
  alias SecantServiceWeb.ValueFormat

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  defp get_parameter_value(module_name, node_id, parameter) do
    case NodeTable.lookup(
           {:service, node_id},
           {:data_report, String.to_existing_atom(module_name),
            String.to_existing_atom(parameter.name)}
         ) do
      {:ok, data_report} ->
        data_report

      {:error, :notfound} ->
        Logger.warning(
          "Data report for module #{module_name} and parameter #{parameter.name} not found in NodeTable for node #{inspect(node_id)}."
        )

        NodeValues.process_data_report(parameter.name, nil, parameter.datainfo)

      {:error, :table_not_found} ->
        Logger.info(
          "ETS table not found for node #{inspect(node_id)}, likely during reconnection. Returning nil."
        )

        NodeValues.process_data_report(parameter.name, nil, parameter.datainfo)
    end
  end

  def get_display_value(raw_value, datainfo, _depth) do
    unit = datainfo["unit"] || ""

    case datainfo["type"] do
      "double" ->
        formatted =
          case raw_value do
            nil ->
              "N/A"

            val when val == 0.0 ->
              "0.0"

            val when abs(val) >= 1000 or abs(val) < 0.001 ->
              # Use scientific notation for very large or very small numbers
              :io_lib.format("~.3e", [val]) |> to_string()

            val ->
              # Use regular decimal notation with up to 6 decimal places, removing trailing zeros
              :io_lib.format("~.6f", [val])
              |> to_string()
              |> String.replace(~r/\.?0+$/, "")
          end

        "#{formatted} #{unit}" |> String.trim()

      "scaled" ->
        formatted =
          case raw_value do
            nil ->
              "N/A"

            val when val == 0.0 ->
              "0"

            val when abs(val) >= 1000 or abs(val) < 0.001 ->
              :io_lib.format("~.3e", [val]) |> to_string()

            val ->
              :io_lib.format("~.6f", [val])
              |> to_string()
              |> String.replace(~r/\.?0+$/, "")
          end

        "#{formatted} #{unit}" |> String.trim()

      "enum" ->
        # Return the name for display
        {name, _} =
          datainfo["members"]
          |> Enum.find(fn
            {_name, val} -> val == raw_value
            _ -> false
          end)

        "#{raw_value}: #{name}"

      _ ->
        if unit == "" do
          "#{Jason.encode!(raw_value, pretty: true)}"
        else
          "#{Jason.encode!(raw_value, pretty: true)} #{unit}"
        end
    end
  end

  def flattened_form_map(
        flattened_map \\ %{},
        path \\ ["value"],
        current_value,
        datainfo,
        depth,
        max_depth
      )

  def flattened_form_map(flattened_map, _path, nil, _datainfo, depth, max_depth)
      when depth < max_depth do
    Map.put(flattened_map, "value", "null")
  end

  def flattened_form_map(flattened_map, path, current_value, datainfo, depth, max_depth)
      when depth < max_depth do
    case datainfo["type"] do
      "struct" ->
        Enum.reduce(datainfo["members"], %{}, fn {member_name, member_info}, acc ->
          if member_info["type"] in ["struct", "tuple"] do
            member_value = Map.get(current_value, String.to_existing_atom(member_name))

            Map.merge(
              acc,
              flattened_form_map(
                %{},
                path ++ [member_name],
                member_value,
                member_info,
                depth + 1,
                max_depth
              )
            )
          else
            member_value = Map.get(current_value, String.to_existing_atom(member_name))
            Map.put(acc, Enum.join(path ++ [member_name], "."), Jason.encode!(member_value))
          end
        end)

      "tuple" ->
        Enum.with_index(datainfo["members"])
        |> Enum.reduce(%{}, fn {member_info, index}, acc ->
          if member_info["type"] in ["struct", "tuple"] do
            member_value = Enum.at(current_value, index)

            Map.merge(
              acc,
              flattened_form_map(
                %{},
                path ++ ["f#{Integer.to_string(index)}"],
                member_value,
                member_info,
                depth + 1,
                max_depth
              )
            )
          else
            member_value = Enum.at(current_value, index)

            Map.put(
              acc,
              Enum.join(path ++ ["f#{Integer.to_string(index)}"], "."),
              Jason.encode!(member_value)
            )
          end
        end)

      _ ->
        Map.put(flattened_map, Enum.join(path, "."), Jason.encode!(current_value))
    end
  end

  def flattened_form_map(flattened_map, path, current_value, _datainfo, depth, max_depth)
      when depth == max_depth do
    Map.put(flattened_map, Enum.join(path, "."), Jason.encode!(current_value))
  end

  @impl true
  def update(
        %{
          class: class,
          host: host,
          port: port,
          module_name: module_name,
          parameter: parameter,
          location: location,
          id_str: id_str
        } = assigns,
        socket
      ) do
    variant = Map.get(assigns, :variant, :row)

    # The parent re-renders these components whenever its own assigns change
    # (e.g. selecting another module). Only (re)initialise forms on first
    # mount or when the parameter itself changed, so text typed into a Set
    # field is not wiped by unrelated re-renders.
    if socket.assigns[:parameter] && socket.assigns.parameter.id == parameter.id do
      {:ok, socket |> assign(:class, class) |> assign(:variant, variant)}
    else
      {:ok, init(socket, host, port, module_name, parameter, location, id_str, class, variant)}
    end
  end

  def update(%{action: :clear_highlight} = _assigns, socket) do
    Logger.info("reset change success")
    socket = assign(socket, :change_success, nil)

    {:ok, socket}
  end

  @impl true
  def update(%{value_update: data_report} = _assigns, socket) do
    socket =
      case data_report do
        %{error_report: [error_cls, error_msg, qualifiers]} ->
          Logger.warning("Error Update: #{error_cls}, #{error_msg}, #{inspect(qualifiers)}")
          assign(socket, :parameter_error, [error_cls, error_msg])

        %{data_report: [value, _qualifiers]} ->
          assign(socket, :parameter_value, value)
          |> assign(:parameter_error, nil)

        _ ->
          Logger.warning("Malformed datareport received: #{IO.inspect(data_report)}")
          socket
      end

    {:ok, socket}
  end

  def update(%{control: :validate, unsigned_params: unsigned_params} = _assigns, socket) do
    updated_socket =
      case unsigned_params["form_type"] do
        "simple" ->
          Logger.info(
            "Simple Form: Validating parameter #{unsigned_params["parameter"]} with value #{unsigned_params["value"]}"
          )

          updated_set_form =
            NodeControl.validate(
              unsigned_params,
              socket.assigns.parameter.datainfo,
              socket.assigns.set_form
            )

          assign(socket, :set_form, updated_set_form)

        "modal" ->
          Logger.info(
            "Modal Form: Validating parameter #{unsigned_params["parameter"]} with value #{unsigned_params["value"]}"
          )

          updated_modal_form =
            NodeControl.validate_modal(
              unsigned_params,
              socket.assigns.parameter.datainfo,
              socket.assigns.modal_form
            )

          assign(socket, :modal_form, updated_modal_form)
      end

    {:ok, updated_socket}
  end

  def update(%{control: :set_parameter, unsigned_params: unsigned_params} = _assigns, socket) do
    form =
      case unsigned_params["form_type"] do
        "simple" ->
          socket.assigns.set_form

        "modal" ->
          socket.assigns.modal_form
      end

    validated_form =
      NodeControl.validate(
        unsigned_params,
        socket.assigns.parameter.datainfo,
        form
      )

    if validated_form.errors != [] do
      updated_socket =
        case unsigned_params["form_type"] do
          "simple" ->
            assign(socket, :set_form, validated_form)

          "modal" ->
            assign(socket, :modal_form, validated_form)
        end

      {:ok, updated_socket}
    else
      # removce pretty formatting for sending to NodeControl.change
      not_pretty_value = Jason.decode!(validated_form.params["value"]) |> Jason.encode!()

      unsigned_params = Map.put(unsigned_params, "value", not_pretty_value)

      ret = NodeControl.change(unsigned_params)
      send_update_after(__MODULE__, %{id: socket.assigns.id_str, action: :clear_highlight}, 1000)

      updated_socket =
        case ret do
          {:changed, _module, _parameter, [value, _qualifiers]} ->
            {:ok, str_value} = Jason.encode(value)

            unsigned_params = Map.put(unsigned_params, "value", str_value)

            updated_form =
              NodeControl.validate(
                unsigned_params,
                socket.assigns.parameter.datainfo,
                validated_form
              )

            socket = assign(socket, :change_success, "btn-success")

            case unsigned_params["form_type"] do
              "simple" ->
                assign(socket, :set_form, updated_form)

              "modal" ->
                assign(socket, :modal_form, updated_form)
            end

          {:error, message_type, specifier, error_class, error_message, _} ->
            Logger.error(
              "Error setting parameter #{unsigned_params["parameter"]}: #{message_type}, #{specifier}, #{error_class}, #{error_message}"
            )

            updated_form = %{
              validated_form
              | errors: [value: {"#{error_class}, #{error_message}", []}]
            }

            socket = assign(socket, :change_success, "btn-error")

            case unsigned_params["form_type"] do
              "simple" ->
                assign(socket, :set_form, updated_form)

              "modal" ->
                assign(socket, :modal_form, updated_form)
            end
        end

      Logger.info("change_success: #{updated_socket.assigns.change_success}")

      {:ok, updated_socket}
    end
  end

  @impl true
  def handle_event("close_parameter_value_modal", _params, socket) do
    {:noreply, assign(socket, show_parameter_value_modal: false)}
  end

  @impl true
  def handle_event("open_parameter_value_modal", _params, socket) do
    {:noreply, assign(socket, show_parameter_value_modal: true)}
  end

  # ---------------------------------------------------------------------------
  # Value rendering, chosen from the datainfo only
  # ---------------------------------------------------------------------------

  attr :value, :any, required: true
  attr :datainfo, :map, required: true
  attr :size, :atom, default: :md

  def value_block(assigns) do
    assigns =
      assigns
      |> assign(:type, assigns.datainfo["type"])
      |> assign(:unit, ValueFormat.unit(assigns.datainfo))

    ~H"""
    <%= cond do %>
      <% @value == nil -> %>
        <span class="text-muted italic">waiting for data…</span>
      <% @type in ["double", "int", "scaled"] -> %>
        <span class={[
          "font-mono",
          if(@size == :lg,
            do: "text-[26px] leading-tight font-medium tracking-tight",
            else: "text-sm"
          )
        ]}>
          {ValueFormat.number(@value)}<span
            :if={@unit != ""}
            class={["ml-1.5 text-muted", if(@size == :lg, do: "text-xs", else: "text-[11px]")]}
          >{@unit}</span>
        </span>
      <% @type == "enum" -> %>
        <span class={["font-mono", if(@size == :lg, do: "text-lg font-semibold", else: "text-sm")]}>
          {ValueFormat.enum_name(@value, @datainfo)}<span class="ml-1.5 text-[11px] text-muted">{@value}</span>
        </span>
      <% @type == "bool" -> %>
        <span class={[
          "inline-flex items-center gap-1.5 rounded border border-line px-2 py-0.5 font-mono text-xs",
          if(@value, do: "text-st-idle", else: "text-muted")
        ]}>
          <span class={["size-2 rounded-full", if(@value, do: "bg-st-idle", else: "bg-st-off")]}></span>
          {to_string(@value)}
        </span>
      <% @type == "struct" -> %>
        <.struct_value value={@value} datainfo={@datainfo} size={@size} />
      <% @type == "array" -> %>
        <.array_value value={@value} datainfo={@datainfo} size={@size} />
      <% @type == "string" -> %>
        <span class="block max-h-32 overflow-y-auto font-mono text-xs break-words whitespace-pre-wrap">{@value}</span>
      <% true -> %>
        <span class="font-mono text-xs break-words">{ValueFormat.short(@value, @datainfo)}</span>
    <% end %>
    """
  end

  attr :value, :any, required: true
  attr :datainfo, :map, required: true
  attr :size, :atom, default: :md

  defp struct_value(assigns) do
    assigns = assign(assigns, :members, assigns.datainfo["members"] || %{})

    ~H"""
    <%= if @size == :lg do %>
      <div class="flex max-h-40 flex-wrap gap-1 overflow-y-auto">
        <span
          :for={{name, info} <- @members}
          class="rounded border border-line bg-base-200 px-1.5 py-0.5 font-mono text-[11px]"
          title={name}
        >
          <span class="text-muted">{name}</span>
          <span class="ml-1">{ValueFormat.short(ValueFormat.member(@value, name), info)}</span>
        </span>
      </div>
    <% else %>
      <dl class="font-mono text-xs">
        <div
          :for={{name, info} <- @members}
          class="flex justify-between gap-3 border-t border-line/60 py-1 first:border-t-0"
        >
          <dt class="shrink-0 text-muted">{name}</dt>
          <dd class="min-w-0 text-right break-words">
            {ValueFormat.short(ValueFormat.member(@value, name), info)}
          </dd>
        </div>
      </dl>
    <% end %>
    """
  end

  attr :value, :any, required: true
  attr :datainfo, :map, required: true
  attr :size, :atom, default: :md

  defp array_value(assigns) do
    values = assigns.value || []
    members = assigns.datainfo["members"] || %{}
    numeric = ValueFormat.numeric_array?(assigns.datainfo)
    height = if assigns.size == :lg, do: 56, else: 64

    assigns =
      assigns
      |> assign(:count, length(values))
      |> assign(:members, members)
      |> assign(:height, height)
      |> assign(:as_spectrum, numeric and length(values) > 8)

    assigns =
      if assigns.as_spectrum do
        {points, lo, hi} = ValueFormat.spectrum(values, 200, height)

        assign(assigns, points: points, lo: lo, hi: hi, unit: ValueFormat.unit(members))
      else
        assigns
      end

    ~H"""
    <%= cond do %>
      <% @as_spectrum -> %>
        <div class="flex flex-col gap-1">
          <svg
            viewBox={"0 0 200 #{@height}"}
            preserveAspectRatio="none"
            class="block w-full border-b border-line"
            style={"height: #{@height}px"}
            role="img"
            aria-label="Latest array value"
          >
            <polyline
              points={@points}
              fill="none"
              stroke="currentColor"
              class="text-primary"
              stroke-width="1.5"
              vector-effect="non-scaling-stroke"
            />
          </svg>
          <div class="flex justify-between gap-2 font-mono text-[11px] text-muted">
            <span>{@count} pts</span>
            <span>{ValueFormat.number(@lo)} … {ValueFormat.number(@hi)} {@unit}</span>
          </div>
        </div>
      <% @count <= 16 -> %>
        <div class="flex flex-wrap gap-1">
          <span :if={@count == 0} class="font-mono text-xs text-muted">[ ] empty</span>
          <span
            :for={v <- @value}
            class="rounded border border-line bg-base-200 px-1.5 py-0.5 font-mono text-[11px]"
          >
            {ValueFormat.short(v, @members)}
          </span>
        </div>
      <% true -> %>
        <span class="font-mono text-xs text-muted">
          array · {@count} items: {ValueFormat.short(Enum.take(@value, 3), %{
            "type" => "array",
            "members" => @members
          })} …
        </span>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  defp set_button_class("btn-success"), do: "border-st-idle text-st-idle"
  defp set_button_class("btn-error"), do: "border-st-error text-st-error"

  defp set_button_class(_),
    do: "border-primary text-ink hover:bg-primary hover:text-primary-content"

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:writable, not assigns.parameter.readonly)
      |> assign(:size, if(assigns.variant == :hero, do: :lg, else: :md))

    ~H"""
    <div class={["min-w-0", @class]}>
      <%= if @variant == :target do %>
        <div class="flex items-baseline justify-between gap-2 text-[11px] text-muted">
          <span>target</span>
          <span class="truncate font-mono" title="current target">
            {ValueFormat.short(@parameter_value, @parameter.datainfo)}
          </span>
        </div>
      <% else %>
        <.value_block value={@parameter_value} datainfo={@parameter.datainfo} size={@size} />
      <% end %>

      <div
        :if={@parameter_error != nil}
        class="mt-1 rounded border border-st-error/50 px-2 py-1 font-mono text-[11px] text-st-error"
      >
        {Enum.at(@parameter_error, 0)}: {Enum.at(@parameter_error, 1)}
      </div>

      <.form
        :if={@writable and @variant != :hero}
        for={@set_form}
        id={"set-form:" <> @id_str}
        phx-submit="set_parameter"
        phx-change="validate_parameter"
        class="form-row mt-1.5 flex items-start gap-1.5"
      >
        <input
          type="hidden"
          name="form_type"
          value={Phoenix.HTML.Form.input_value(@set_form, :form_type)}
        />
        <input type="hidden" name="port" value={Phoenix.HTML.Form.input_value(@set_form, :port)} />
        <input type="hidden" name="host" value={Phoenix.HTML.Form.input_value(@set_form, :host)} />
        <input
          type="hidden"
          name="location"
          value={Phoenix.HTML.Form.input_value(@set_form, :location)}
        />
        <input type="hidden" name="module" value={Phoenix.HTML.Form.input_value(@set_form, :module)} />
        <input type="hidden" name="parameter" value={@parameter.name} />
        <%= if @parameter.datainfo["type"] == "enum" do %>
          <.input_enum
            id={"form:" <> to_string(@parameter.id) <> @location}
            datainfo={@parameter.datainfo}
            location={@location}
            modal_form={@set_form}
            parameter_id={@parameter.id}
            show_tooltip={false}
            class="select-sm w-full font-mono text-xs"
          />
        <% else %>
          <.input
            name="value"
            type="text"
            field={@set_form[:value]}
            placeholder={set_placeholder(@parameter.datainfo)}
            phx-debounce="400"
            autocomplete="off"
            id={"form:" <> to_string(@parameter.id) <> @location}
            class="input input-sm w-full font-mono text-xs"
          />
        <% end %>
        <button
          type="submit"
          class={[
            "btn btn-sm shrink-0 border bg-transparent font-semibold",
            set_button_class(@change_success)
          ]}
        >
          Set
        </button>
        <button
          :if={@is_composite}
          type="button"
          onclick={"modal_" <> to_string(@parameter.id) <> @location <> ".showModal()"}
          phx-click="open_parameter_value_modal"
          phx-target={@myself}
          class="btn btn-sm btn-ghost shrink-0 border border-line"
          title="Edit field by field"
        >
          Edit…
        </button>
      </.form>

      <.modal
        :if={@writable and @is_composite and @variant != :hero}
        id={"modal_" <> to_string(@parameter.id) <> @location}
        title={"Set #{@module_name}:#{@parameter.name}"}
        show={@show_parameter_value_modal}
      >
        <.form for={@modal_form} phx-submit="set_parameter" phx-change="validate_parameter">
          <input
            type="hidden"
            name="form_type"
            value={Phoenix.HTML.Form.input_value(@modal_form, :form_type)}
          />
          <input type="hidden" name="port" value={Phoenix.HTML.Form.input_value(@modal_form, :port)} />
          <input type="hidden" name="host" value={Phoenix.HTML.Form.input_value(@modal_form, :host)} />
          <input
            type="hidden"
            name="location"
            value={Phoenix.HTML.Form.input_value(@modal_form, :location)}
          />
          <input
            type="hidden"
            name="module"
            value={Phoenix.HTML.Form.input_value(@modal_form, :module)}
          />

          <.input_parameter
            datainfo={@parameter.datainfo}
            modal_form={@modal_form}
            parameter_id={to_string(@parameter.id)}
            location={@location}
          />

          <input type="hidden" name="parameter" value={@parameter.name} />
          <div class="mt-2 text-xs text-muted">JSON preview</div>
          <.input
            id={to_string(@parameter.id) <> @location <> "_preview"}
            name="value"
            type="textarea"
            field={@modal_form[:value]}
            value={Phoenix.HTML.Form.input_value(@modal_form, :value)}
            rows="14"
            class="textarea w-full font-mono text-xs"
          />
          <button type="submit" class={["btn btn-primary mt-2", @change_success]}>
            Set
          </button>
        </.form>
      </.modal>
    </div>
    """
  end

  defp init(socket, host, port, module_name, parameter, location, id_str, class, variant) do
    node_id = {String.to_charlist(host), port}

    val_map = get_parameter_value(module_name, node_id, parameter)

    socket =
      case val_map do
        %{error_report: [error_cls, error_msg, _qualifiers]} ->
          assign(socket, :parameter_error, [error_cls, error_msg])
          |> assign(:parameter_value, nil)

        %{data_report: [value, _qualifiers]} ->
          assign(socket, :parameter_value, value)
          |> assign(:parameter_error, nil)

        _ ->
          assign(socket, :parameter_value, nil)
          |> assign(:parameter_error, nil)
      end

    flat_map =
      flattened_form_map(%{}, ["value"], socket.assigns.parameter_value, parameter.datainfo, 0, 1)

    base_form = %{
      "location" => "#{location}",
      "host" => to_string(host),
      "port" => Integer.to_string(port),
      "parameter" => parameter.name,
      "module" => module_name,
      "value" => Jason.encode!(socket.assigns.parameter_value, pretty: true),
      "form_type" => "simple"
    }

    set_form =
      case parameter.datainfo["type"] do
        "enum" -> base_form
        _ -> base_form |> Map.put("value", nil)
      end

    set_form = to_form(set_form)

    modal_form =
      base_form
      |> Map.put("form_type", "modal")
      |> Map.merge(flat_map)
      |> to_form()

    socket
    |> assign(:parameter, parameter)
    |> assign(:module_name, module_name)
    |> assign(:node_id, node_id)
    |> assign(:host, host)
    |> assign(:port, port)
    |> assign(:class, class)
    |> assign(:variant, variant)
    |> assign(:set_form, set_form)
    |> assign(:modal_form, modal_form)
    |> assign(:location, location)
    |> assign(:show_parameter_value_modal, false)
    |> assign(:is_composite, parameter.datainfo["type"] in ["struct", "tuple"])
    |> assign(:change_success, nil)
    |> assign(:id_str, id_str)
  end

  defp set_placeholder(datainfo) do
    case {ValueFormat.limits(datainfo), ValueFormat.unit(datainfo)} do
      {nil, ""} -> "new value (#{ValueFormat.type_label(datainfo)})"
      {nil, unit} -> "new value [#{unit}]"
      {limits, unit} -> String.trim("#{limits} #{unit}")
    end
  end
end
