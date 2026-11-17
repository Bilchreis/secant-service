defmodule SecantServiceWeb.Components.ParameterFormFieldComponents do
  use Phoenix.Component
  import SecantServiceWeb.CoreComponents

  attr :datainfo, :map, required: true
  attr :modal_form, :map, required: true
  attr :depth, :integer, default: 0
  attr :max_depth, :integer, default: 1
  attr :path, :list, default: ["value"]
  attr :parameter_id, :string, required: true
  attr :location, :string, required: true

  def input_parameter(assigns) do
    ~H"""
    <%= case @datainfo["type"] do %>
      <% "struct" -> %>
        <.input_struct
          datainfo={@datainfo}
          location={@location}
          modal_form={@modal_form}
          depth={@depth}
          max_depth={@max_depth}
          path={@path}
          parameter_id={@parameter_id}
        />
      <% "tuple" -> %>
        <.input_tuple
          datainfo={@datainfo}
          location={@location}
          modal_form={@modal_form}
          depth={@depth}
          max_depth={@max_depth}
          path={@path}
          parameter_id={@parameter_id}
        />
      <% type when type in ["double", "int", "scaled"] -> %>
        <.input_numeric
          datainfo={@datainfo}
          location={@location}
          modal_form={@modal_form}
          depth={@depth}
          max_depth={@max_depth}
          path={@path}
          parameter_id={@parameter_id}
        />
      <% "bool" -> %>
        <.input_bool
          datainfo={@datainfo}
          location={@location}
          modal_form={@modal_form}
          depth={@depth}
          max_depth={@max_depth}
          path={@path}
          parameter_id={@parameter_id}
        />
      <% "enum" -> %>
        <.input_enum
          datainfo={@datainfo}
          location={@location}
          modal_form={@modal_form}
          depth={@depth}
          max_depth={@max_depth}
          path={@path}
          parameter_id={@parameter_id}
        />
      <% "array" -> %>
        <.input_array
          datainfo={@datainfo}
          location={@location}
          modal_form={@modal_form}
          depth={@depth}
          max_depth={@max_depth}
          path={@path}
          parameter_id={@parameter_id}
        />
      <% "string" -> %>
        <.input_string
          datainfo={@datainfo}
          location={@location}
          modal_form={@modal_form}
          depth={@depth}
          max_depth={@max_depth}
          path={@path}
          parameter_id={@parameter_id}
        />
      <% "blob" -> %>
        blob
      <% "matrix" -> %>
        matrix
      <% _ -> %>
        unknown type
    <% end %>
    """
  end

  attr :datainfo, :map, required: true
  attr :modal_form, :map, required: true
  attr :depth, :integer, default: 0
  attr :max_depth, :integer, default: 1
  attr :path, :list, default: ["value"]
  attr :parameter_id, :integer, required: true
  attr :location, :string, required: true

  def input_numeric(assigns) do
    assigns =
      assigns
      |> assign(:field, Enum.join(assigns.path, "."))

    assigns =
      assign(
        assigns,
        :input_id,
        "#{assigns.parameter_id}-#{assigns.location}-#{assigns.modal_form[assigns.field].id}"
      )

    ~H"""
    <.input
      id={@input_id}
      name={@field}
      type="number"
      field={@modal_form[@field]}
      value={Phoenix.HTML.Form.input_value(@modal_form, @field)}
      class="input input-sm w-full font-mono text-xs"
    />

    <.datainfo_tooltip datainfo={@datainfo} />
    """
  end

  attr :datainfo, :map, required: true
  attr :modal_form, :map, required: true
  attr :depth, :integer, default: 0
  attr :max_depth, :integer, default: 1
  attr :path, :list, default: ["value"]
  attr :parameter_id, :integer, required: true
  attr :location, :string, required: true

  def input_string(assigns) do
    assigns =
      assigns
      |> assign(:field, Enum.join(assigns.path, "."))

    assigns =
      assign(
        assigns,
        :input_id,
        "#{assigns.parameter_id}-#{assigns.location}-#{assigns.modal_form[assigns.field].id}"
      )

    ~H"""
    <.input
      id={@input_id}
      name={@field}
      type="text"
      field={@modal_form[@field]}
      value={Phoenix.HTML.Form.input_value(@modal_form, @field)}
      class="input input-sm w-full font-mono text-xs"
    />
    <.datainfo_tooltip datainfo={@datainfo} />
    """
  end

  attr :datainfo, :map, required: true
  attr :modal_form, :map, required: true
  attr :depth, :integer, default: 0
  attr :max_depth, :integer, default: 1
  attr :path, :list, default: ["value"]
  attr :parameter_id, :integer, required: true
  attr :location, :string, required: true

  def input_bool(assigns) do
    assigns =
      assigns
      |> assign(:field, Enum.join(assigns.path, "."))

    assigns =
      assign(
        assigns,
        :input_id,
        "#{assigns.parameter_id}-#{assigns.location}-#{assigns.modal_form[assigns.field].id}"
      )

    ~H"""
    <.input
      name={@field}
      type="checkbox"
      field={@modal_form[@field]}
      value={Phoenix.HTML.Form.input_value(@modal_form, @field)}
      class="checkbox checkbox-sm"
    />
    <.datainfo_tooltip datainfo={@datainfo} />
    """
  end

  attr :datainfo, :map, required: true
  attr :modal_form, :map, required: true
  attr :depth, :integer, default: 0
  attr :max_depth, :integer, default: 1
  attr :path, :list, default: ["value"]
  attr :parameter_id, :string, required: true
  attr :location, :string, required: true
  attr :show_tooltip, :boolean, default: true
  attr :id, :string, default: nil
  attr :class, :string, default: ""

  def input_enum(assigns) do
    select_options = assigns.datainfo["members"]

    base_class =
      "select select-sm w-full font-mono text-xs"

    class = if assigns[:class], do: "#{base_class} #{assigns[:class]}", else: base_class

    assigns =
      assigns
      |> assign(:field, Enum.join(assigns.path, "."))
      |> assign(:options, select_options)
      |> assign(:class, class)

    assigns =
      assign(
        assigns,
        :input_id,
        "#{assigns.parameter_id}-#{assigns.location}-#{assigns.modal_form[assigns.field].id}"
      )

    ~H"""
    <.input
      id={@input_id}
      name={@field}
      type="select"
      options={@options}
      field={@modal_form[@field]}
      value={Phoenix.HTML.Form.input_value(@modal_form, @field)}
      class={@class}
    />
    <%= if @show_tooltip do %>
      <.datainfo_tooltip datainfo={@datainfo} />
    <% end %>
    """
  end

  attr :datainfo, :map, required: true
  attr :modal_form, :map, required: true
  attr :depth, :integer, default: 0
  attr :max_depth, :integer, default: 1
  attr :path, :list, default: ["value"]
  attr :parameter_id, :integer, required: true
  attr :location, :string, required: true

  def input_struct(assigns) do
    assigns =
      assigns
      |> assign(:field, Enum.join(assigns.path, "."))
      |> assign(
        :grid_cols,
        if(length(Map.to_list(assigns.datainfo["members"])) > 6,
          do: "grid-cols-3",
          else: "grid-cols-1"
        )
      )

    assigns =
      assign(
        assigns,
        :input_id,
        "#{assigns.parameter_id}-#{assigns.location}-#{assigns.modal_form[assigns.field].id}"
      )

    ~H"""
    Struct:
    <%= if @depth >= @max_depth do %>
      <.input
        id={@input_id}
        name={@field}
        type="text"
        field={@modal_form[@field]}
        value={Phoenix.HTML.Form.input_value(@modal_form, @field)}
        class="input input-sm w-full font-mono text-xs"
      />
      <.datainfo_tooltip datainfo={@datainfo} />
    <% else %>
      <div class={"grid #{@grid_cols} gap-x-2 gap-y-2 items-center border-line rounded-lg  border p-2"}>
        <%= for {member_name, member_info} <- @datainfo["members"] do %>
          <div class="grid grid-cols-2 gap-2 items-center w-full">
            <div class="text-right text-xs font-medium text-muted wrap-anywhere">
              {member_name}:
            </div>
            <div class="flex items-center gap-2 [&>.fieldset]:mb-0 [&>.fieldset]:min-w-0 [&>.fieldset]:flex-1">
              <.input_parameter
                datainfo={member_info}
                path={@path ++ [member_name]}
                modal_form={@modal_form}
                depth={@depth + 1}
                max_depth={@max_depth}
                parameter_id={@parameter_id}
                location={@location}
              />
            </div>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  attr :datainfo, :map, required: true
  attr :modal_form, :map, required: true
  attr :depth, :integer, default: 0
  attr :max_depth, :integer, default: 1
  attr :path, :list, default: ["value"]
  attr :parameter_id, :integer, required: true
  attr :location, :string, required: true

  def input_tuple(assigns) do
    assigns =
      assigns
      |> assign(:field, Enum.join(assigns.path, "."))
      |> assign(
        :grid_cols,
        if(length(assigns.datainfo["members"]) > 6, do: "grid-cols-3", else: "grid-cols-1")
      )

    assigns =
      assign(
        assigns,
        :input_id,
        "#{assigns.parameter_id}-#{assigns.location}-#{assigns.modal_form[assigns.field].id}"
      )

    ~H"""
    Tuple:
    <%= if @depth >= @max_depth do %>
      <.input
        id={@input_id}
        name={@field}
        type="text"
        field={@modal_form[@field]}
        value={Phoenix.HTML.Form.input_value(@modal_form, @field)}
        class="input input-sm w-full font-mono text-xs"
      />
      <.datainfo_tooltip datainfo={@datainfo} />
    <% else %>
      <div class={"grid #{@grid_cols} gap-x-2 gap-y-2 items-center border-line rounded-lg p-2"}>
        <%= for {member_info, index} <- Enum.with_index(@datainfo["members"]) do %>
          <div class="text-right text-xs font-medium text-muted wrap-anywhere">
            {"f#{index}"}:
          </div>
          <div class="flex items-center gap-2 [&>.fieldset]:mb-0 [&>.fieldset]:min-w-0 [&>.fieldset]:flex-1">
            <.input_parameter
              datainfo={member_info}
              path={@path ++ ["f#{index}"]}
              modal_form={@modal_form}
              depth={@depth + 1}
              max_depth={@max_depth}
              parameter_id={@parameter_id}
              location={@location}
            />
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  attr :datainfo, :map, required: true
  attr :modal_form, :map, required: true
  attr :depth, :integer, default: 0
  attr :max_depth, :integer, default: 1
  attr :path, :list, default: ["value"]
  attr :parameter_id, :integer, required: true
  attr :location, :string, required: true

  def input_array(assigns) do
    assigns =
      assigns
      |> assign(:field, Enum.join(assigns.path, "."))
      |> assign(
        :popover_id,
        "popover-" <>
          assigns.location <> "-" <> assigns.parameter_id <> Enum.join(assigns.path, "-")
      )

    assigns =
      assign(
        assigns,
        :input_id,
        "#{assigns.parameter_id}-#{assigns.location}-#{assigns.modal_form[assigns.field].id}"
      )

    ~H"""
    <.input
      id={@input_id}
      name={@field}
      type="text"
      field={@modal_form[@field]}
      value={Phoenix.HTML.Form.input_value(@modal_form, @field)}
      class="input input-sm w-full font-mono text-xs"
    />

    <.datainfo_tooltip datainfo={@datainfo} />
    """
  end

  attr :datainfo, :string, required: true
  attr :position, :string, default: "tooltip-top"

  def datainfo_tooltip(assigns) do
    assigns =
      assigns
      |> assign(:pretty_datainfo, Jason.encode!(assigns.datainfo, pretty: true))

    ~H"""
    <span
      class={["inline-flex shrink-0 cursor-help", @position]}
      title={"Datainfo:\n" <> @pretty_datainfo}
    >
      <.icon name="hero-information-circle" class="size-4 text-muted" />
    </span>
    """
  end
end
