defmodule SecantServiceWeb.Components.ModuleIndicator do
  use Phoenix.LiveComponent

  require Logger

  alias NodeTable
  alias SecantService.Util
  alias SecantService.NodeValues
  alias SecantServiceWeb.SECoPComponents

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  defp get_status_value(module_name, node_id, status_param) do
    stat_val =
      if status_param != nil do
        stat_val =
          case NodeTable.lookup(
                 {:service, node_id},
                 {:data_report, String.to_existing_atom(module_name), :status}
               ) do
            {:ok, data_report} ->
              data_report

            {:error, :notfound} ->
              Logger.warning(
                "Data report for module #{module_name} and parameter status not found in NodeTable for node #{inspect(node_id)}}."
              )

              NodeValues.process_data_report(status_param.name, nil, status_param.datainfo)
          end

        stat_val
      else
        nil
      end

    stat_val
  end

  @impl true
  def update(
        %{
          host: host,
          port: port,
          module_name: module_name,
          highest_if_class: highest_if_class,
          status_param: status_param,
          node_state: node_state,
          indicator_select: indicator_select
        } = _assigns,
        socket
      ) do
    node_id = {String.to_charlist(host), port}

    socket =
      socket
      |> assign(:highest_if_class, highest_if_class)
      |> assign(:status_param, status_param)
      |> assign(:module_name, module_name)
      |> assign(:node_state, node_state)
      |> assign(:node_id, node_id)
      |> assign(:indicator_select, indicator_select)
      |> assign_new(:status_value, fn -> get_status_value(module_name, node_id, status_param) end)

    {:ok, socket}
  end

  @impl true
  def update(%{value_update: processed_value_update} = _assigns, socket) do
    {:ok, assign(socket, :status_value, processed_value_update)}
  end

  defp status_parts(nil), do: {"bg-st-off", "text-muted", nil, nil}

  defp status_parts(%{data_report: nil}), do: {"bg-st-off", "text-muted", nil, nil}

  defp status_parts(status_value) do
    {SECoPComponents.status_to_color(status_value.stat_color),
     SECoPComponents.status_to_text(status_value.stat_color), to_string(status_value.stat_code),
     status_value.stat_string}
  end

  attr :status_value, :map, default: nil
  attr :node_state, :atom, default: :initialized
  attr :module_name, :string, required: true
  attr :has_status, :boolean, default: true

  # Row in the module rail: dot, name, status code.
  defp rail_row(assigns) do
    {dot, text, code, string} = status_parts(assigns.status_value)

    {dot, text, code} =
      cond do
        not assigns.has_status -> {"bg-st-off/50", "text-muted", ""}
        assigns.node_state != :initialized -> {"bg-st-off", "text-muted", "offline"}
        true -> {dot, text, code}
      end

    assigns =
      assigns
      |> assign(dot: dot, text: text, code: code, string: string)

    ~H"""
    <span class="flex min-w-0 flex-1 items-center gap-2" title={@string}>
      <span class={["size-2 shrink-0 rounded-full", @dot]}></span>
      <span class="min-w-0 flex-1 truncate">{Util.display_name(@module_name)}</span>
      <span :if={@code} class={["shrink-0 font-mono text-[10.5px] font-semibold", @text]}>{@code}</span>
    </span>
    """
  end

  attr :status_value, :map, default: nil
  attr :layout, :atom, default: :stacked

  # Status chip for cards and the inspector: dot + code, then the status text.
  defp status_chip(assigns) do
    {dot, text, code, string} = status_parts(assigns.status_value)
    assigns = assign(assigns, dot: dot, text: text, code: code, string: string)

    ~H"""
    <div class="min-w-0">
      <span class={["inline-flex items-center gap-1.5 font-mono text-[11px] font-semibold", @text]}>
        <span class={["size-2 rounded-full", @dot]}></span>
        {@code || "no data"}
      </span>
      <div
        :if={@layout == :stacked}
        class="mt-0.5 min-h-4 truncate text-[11.5px] text-muted"
        title={@string}
      >
        {@string}
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="contents">
      <%= case @indicator_select do %>
        <% :outer -> %>
          <.rail_row
            status_value={@status_value}
            node_state={@node_state}
            module_name={@module_name}
            has_status={@status_param != nil}
          />
        <% :inner -> %>
          <.status_chip status_value={@status_value} layout={:stacked} />
        <% :compact -> %>
          <.status_chip status_value={@status_value} layout={:inline} />
      <% end %>
    </div>
    """
  end
end
