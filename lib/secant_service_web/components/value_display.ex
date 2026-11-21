defmodule SecantServiceWeb.Components.ValueDisplay do
  @moduledoc """
  How a parameter value looks, chosen from its datainfo only: scalars, enums
  as badges, structs field by field, arrays as a compact list.
  """
  use Phoenix.Component

  alias SecantServiceWeb.ValueFormat

  attr :id, :string, required: true
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
            do: "text-[32px] leading-tight font-medium tracking-tight",
            else: "text-sm"
          )
        ]}>
          {ValueFormat.number(@value)}<span
            :if={@unit != ""}
            class={["ml-1.5 text-muted", "text-xs"]}
          >{@unit}</span>
        </span>
      <% @type == "enum" -> %>
        <.enum_badge value={@value} datainfo={@datainfo} size={@size} />
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
        <.array_value id={@id} value={@value} datainfo={@datainfo} size={@size} />
      <% @type == "string" and @value == "" -> %>
        <span class="font-mono text-xs text-muted italic">"" (empty)</span>
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

  @doc "Enum value as a coloured badge: member name and code."
  def enum_badge(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex w-fit max-w-full min-w-0 items-center gap-1.5 rounded-md border font-mono",
        ValueFormat.enum_class(@value),
        case @size do
          :lg -> "px-2.5 py-1 text-base font-semibold"
          :md -> "px-2 py-0.5 text-sm"
          _ -> "px-1.5 py-px text-[11px]"
        end
      ]}
      title={ValueFormat.enum_name(@value, @datainfo)}
    >
      <span :if={@size == :sm} class="wrap-anywhere">
        {ValueFormat.breakable(ValueFormat.enum_name(@value, @datainfo))}
      </span>
      <span :if={@size != :sm} class="truncate">{ValueFormat.enum_name(@value, @datainfo)}</span>
      <span class="shrink-0 rounded-full bg-white/70 px-1.5 text-[11px] font-normal dark:bg-black/30">
        {@value}
      </span>
    </span>
    """
  end

  attr :value, :any, required: true
  attr :datainfo, :map, required: true
  attr :size, :atom, default: :md

  defp struct_value(assigns) do
    assigns = assign(assigns, :members, assigns.datainfo["members"] || %{})

    # field names right-aligned in one column, values (enums as coloured
    # badges) in the other; long names and enum values wrap
    ~H"""
    <dl class={[
      "grid grid-cols-[minmax(0,max-content)_minmax(7rem,1fr)] items-center gap-x-2 font-mono",
      if(@size == :lg, do: "max-h-48 gap-y-1 overflow-y-auto text-xs", else: "gap-y-1.5 text-xs")
    ]}>
      <%= for {name, info} <- @members do %>
        <dt class="text-right text-muted wrap-anywhere" title={name}>
          {ValueFormat.breakable(name)}
        </dt>
        <dd class="min-w-0">
          <%= if ValueFormat.enum?(info) do %>
            <.enum_badge value={ValueFormat.member(@value, name)} datainfo={info} size={:sm} />
          <% else %>
            <span
              class="block truncate"
              title={ValueFormat.short(ValueFormat.member(@value, name), info)}
            >
              {ValueFormat.short(ValueFormat.member(@value, name), info)}
            </span>
          <% end %>
        </dd>
      <% end %>
    </dl>
    """
  end

  attr :id, :string, required: true
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
        {points, lo, hi} = ValueFormat.spectrum(values)

        assign(assigns,
          points: Jason.encode!(points),
          lo: lo,
          hi: hi,
          unit: SecantService.PlotDB.DTypes.ArrayHeatmap.unit(assigns.datainfo) || ""
        )
      else
        assigns
      end

    ~H"""
    <%= cond do %>
      <% @as_spectrum -> %>
        <div class="flex flex-col gap-1">
          <%!-- drawn by the ArraySpark hook; the points attribute updates with each reading --%>
          <div
            id={"spark-arr:" <> @id}
            phx-hook="ArraySpark"
            phx-update="ignore"
            data-points={@points}
            data-n={@count}
            data-unit={@unit}
            class="relative w-full border-b border-line"
            style={"height: #{@height}px"}
            role="img"
            aria-label={"latest array value, #{@count} points"}
          >
            <div data-role="chart" class="absolute inset-0"></div>
          </div>
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
            class={[
              "rounded border px-1.5 py-0.5 font-mono text-[11px]",
              if(ValueFormat.enum?(@members),
                do: ValueFormat.enum_class(v),
                else: "border-line bg-base-200"
              )
            ]}
          >
            {case ValueFormat.short(v, @members) do
              "" -> "—"
              s -> s
            end}
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
end
