defmodule SecantServiceWeb.Components.HistoryDB do
  use Phoenix.LiveComponent
  import SecantServiceWeb.CoreComponents
  require Logger
  alias SecantService.PlotDB
  alias SecantService.PlotDB.Builders
  alias SecantService.SecNodes.ParameterValue
  alias Phoenix.LiveView.JS
  alias Phoenix.LiveView.AsyncResult

  defp get_tabledata(secop_obj, params \\ %{}) do
    parameter = get_parameter(secop_obj)

    resource = ParameterValue.get_resource_module(parameter)

    # Ensure default pagination parameters are set
    params_with_defaults = Map.merge(%{limit: 20, page: 1, order_by: ["-timestamp"]}, params)

    case AshPagify.validate_and_run(resource, params_with_defaults, [action: :for_parameter], %{
           parameter_id: parameter.id
         }) do
      {:ok, {parameter_values, meta}} ->
        {:ok, %{table_data: %{parameter_values: parameter_values, meta: meta}}}

      {:error, reason} ->
        Logger.error("Error fetching parameter values: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def mount(socket) do
    {:ok, assign(socket, :chart_height, 340)}
  end

  defp chart_height(%{option: %{_structFields: fields}}, base) when is_map(fields) do
    max(map_size(fields) * 80, base)
  end

  defp chart_height(_, base), do: base

  defp get_parameter(secop_obj) do
    case secop_obj do
      %SecantService.SecNodes.Parameter{} = param ->
        param

      %SecantService.SecNodes.Module{} = module ->
        Enum.find(module.parameters, nil, fn param -> param.name == "value" end)
    end
  end

  # Resolves a plot's parameter name (e.g. "target") back to its %Parameter{} struct.
  # A bare %Parameter{} secop_obj only ever has itself, regardless of the name PlotDB
  # reports (e.g. array-heatmap plots report "value" for a parameter that isn't named that).
  defp resolve_param(%SecantService.SecNodes.Parameter{} = param, _name), do: param

  defp resolve_param(%SecantService.SecNodes.Module{} = module, name),
    do: Builders.find_param(module, name)

  defp async_result_value(%AsyncResult{ok?: true, result: result}), do: result
  defp async_result_value(_), do: nil

  # Combines the per-parameter trace-update maps produced for each series of a
  # multi-parameter plot (e.g. drivable's "value"/"target") into the single
  # payload the EChartsChart hook expects for one prepend-chart-data event.
  defp merge_trace_updates(updates_list) do
    series_updates = Enum.flat_map(updates_list, &Map.get(&1, :seriesUpdates, []))
    array_len = Enum.find_value(updates_list, &Map.get(&1, :arrayLen))

    case array_len do
      nil -> %{seriesUpdates: series_updates}
      len -> %{seriesUpdates: series_updates, arrayLen: len}
    end
  end

  def tabular?(%SecantService.SecNodes.Module{} = module) do
    if get_parameter(module) do
      true
    else
      false
    end
  end

  def tabular?(%SecantService.SecNodes.Parameter{} = _parameter) do
    true
  end

  @impl true
  def update(%{secop_obj: secop_obj} = assigns, socket) do
    initialized = socket.assigns[:initialised] || false

    socket =
      if initialized do
        socket
      else
        socket =
          socket
          |> assign(:table_data, nil)
          |> assign(:plot, nil)
          |> assign(:calibration_plot, nil)

        plot_mode = assigns[:plot_mode] || :live

        ifclass =
          case secop_obj do
            %SecantService.SecNodes.Parameter{} = _param -> nil
            %SecantService.SecNodes.Module{} = module -> module.highest_interface_class
          end

        socket =
          cond do
            PlotDB.plottable?(secop_obj) ->
              assign(socket, :display_mode, :graph)
              |> assign(:plottable, true)
              |> assign(:plot_mode, plot_mode)
              |> assign(:plot, AsyncResult.loading())
              |> start_async(:load_plot, fn -> PlotDB.init(secop_obj, plot_mode) end)

            tabular?(secop_obj) ->
              assign(socket, :display_mode, :table)
              |> assign(:plottable, false)
              |> assign(:plot_mode, plot_mode)
              |> assign_async(:table_data, fn -> get_tabledata(secop_obj) end)

            true ->
              assign(socket, :display_mode, :empty)
              |> assign(:plottable, false)
              |> assign(:plot_mode, plot_mode)
          end

        socket
        |> assign(:initialised, true)
        |> assign(:base_height, assigns[:height] || 340)
        |> assign(:chart_height, assigns[:height] || 340)
        |> assign(:id, assigns.id)
        |> assign(:class, assigns.class)
        |> assign(:parameter, get_parameter(secop_obj))
        |> assign(:secop_obj, secop_obj)
        |> assign(:interface_class, ifclass)
      end

    {:ok, socket}
  end

  def update(%{value_update: value_update_list, parameter: parameter} = _assigns, socket) do
    param_list = PlotDB.param_list(socket.assigns.secop_obj)

    socket =
      if socket.assigns.plottable and parameter in param_list and socket.assigns.plot.ok? do
        validated_datapoints =
          Enum.reduce(value_update_list, [], fn [value, qualifiers], acc ->
            case qualifiers do
              %{t: timestamp} ->
                # Convert to milliseconds if needed
                timestamp = trunc(timestamp * 1000)
                [{value, timestamp} | acc]

              _ ->
                acc
            end
          end)
          |> Enum.reverse()

        if length(validated_datapoints) > 0 do
          update_data =
            PlotDB.get_trace_updates_batch(
              socket.assigns.plot.result,
              validated_datapoints,
              parameter
            )

          push_event(socket, "extend-chart-#{socket.assigns.id}", update_data)
        else
          socket
        end
      else
        socket
      end

    socket =
      if socket.assigns[:display_mode] == :calibration &&
           parameter in [
             "_forward_calibration_coefficients",
             "_inverse_calibration_coefficients",
             "_forward_calib_coeff",
             "_inverse_calib_coeff"
           ] do
        secop_obj = socket.assigns.secop_obj

        start_async(socket, :reload_calibration_plot, fn ->
          PlotDB.calibration_plot(secop_obj)
        end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("fetch-chart-range", %{"from" => from_ms, "to" => to_ms}, socket) do
    secop_obj = socket.assigns.secop_obj
    plot = socket.assigns.plot.result
    param_names = PlotDB.param_list(secop_obj)

    socket =
      start_async(socket, :fetch_chart_range, fn ->
        param_names
        |> Enum.map(&resolve_param(secop_obj, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(fn param ->
          {values, timestamps} = Builders.fetch_param_data_in_range(param, from_ms, to_ms)
          datapoints = Enum.zip(values, timestamps)
          PlotDB.get_trace_updates_batch(plot, datapoints, param.name)
        end)
        |> merge_trace_updates()
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("request-chart-data", %{"id" => chart_id}, %{assigns: assigns} = socket) do
    # Only push when a chart option actually exists — a plot result may be a
    # not_plottable/no_plot_available map without an :option key.
    {event, plot_result} =
      if String.ends_with?(chart_id, "-calib") do
        {"echarts-data-#{chart_id}", async_result_value(assigns[:calibration_plot])}
      else
        {"echarts-data-#{socket.assigns.id}", async_result_value(assigns[:plot])}
      end

    case plot_result do
      %{option: option} -> {:noreply, push_event(socket, event, %{option: option})}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("paginate", %{"offset" => offset}, socket) do
    %{parameter_values: _paramerter_values, meta: current_meta} = socket.assigns.table_data.result
    old_params = current_meta.params

    offset = Integer.parse(offset) |> elem(0)

    # Update the meta with new sort params
    params = Map.put(old_params, :offset, offset)

    secop_obj = socket.assigns.parameter

    # Fetch data with new sort parameters
    socket =
      assign_async(socket, :table_data, fn ->
        get_tabledata(secop_obj, params)
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("sort", %{"order" => field}, socket) do
    %{parameter_values: _paramerter_values, meta: current_meta} = socket.assigns.table_data.result

    old_params = current_meta.params

    ash_pagify = AshPagify.push_order(current_meta.ash_pagify, field)

    # Update the meta with new sort params
    params =
      Map.put(old_params, :order_by, ash_pagify.order_by)

    secop_obj = socket.assigns.parameter

    socket =
      assign_async(socket, :table_data, fn ->
        get_tabledata(secop_obj, params)
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("set-display-mode", %{"mode" => mode}, socket) do
    display_mode = String.to_existing_atom(mode)
    secop_obj = socket.assigns.secop_obj

    socket =
      case display_mode do
        :graph ->
          socket =
            if socket.assigns.plot == nil do
              plot_mode = socket.assigns[:plot_mode] || :live

              socket
              |> assign(:plot, AsyncResult.loading())
              |> start_async(:load_plot, fn -> PlotDB.init(secop_obj, plot_mode) end)
            else
              socket
            end

          # Eagerly push already-loaded plot data so it is batched with the DOM
          # diff. LiveView guarantees push_events fire only after the diff is
          # applied (hook mounted, handleEvent registered), avoiding the round-
          # trip race between pushEventTo → request-plotly-data → push_event.
          case socket.assigns[:plot] do
            %{ok?: true, result: %{option: _} = plot} ->
              push_event(socket, "echarts-data-#{socket.assigns.id}", %{
                option: plot.option
              })

            _ ->
              socket
          end

        :table ->
          if socket.assigns.table_data == nil do
            socket |> assign_async(:table_data, fn -> get_tabledata(secop_obj) end)
          else
            socket
          end

        :calibration ->
          if socket.assigns.calibration_plot == nil do
            secop_obj = socket.assigns.secop_obj

            socket
            |> assign_async(:calibration_plot, fn ->
              {:ok, %{calibration_plot: PlotDB.calibration_plot(secop_obj)}}
            end)
          else
            socket
          end

        _ ->
          socket
      end

    {:noreply, assign(socket, :display_mode, display_mode)}
  end

  @impl true
  def handle_async(:load_plot, {:ok, plot}, socket) do
    socket =
      socket
      |> assign(:plot, AsyncResult.ok(socket.assigns.plot, plot))
      |> assign(:chart_height, chart_height(plot, socket.assigns.base_height))

    socket =
      if socket.assigns.display_mode == :graph and Map.get(plot, :plottable) and
           Map.get(plot, :option) do
        push_event(socket, "echarts-data-#{socket.assigns.id}", %{
          option: plot.option
        })
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_async(:load_plot, {:exit, reason}, socket) do
    {:noreply, assign(socket, :plot, AsyncResult.failed(socket.assigns.plot, {:exit, reason}))}
  end

  def handle_async(:fetch_chart_range, {:ok, update_data}, socket) do
    {:noreply, push_event(socket, "prepend-chart-data-#{socket.assigns.id}", update_data)}
  end

  def handle_async(:fetch_chart_range, {:exit, reason}, socket) do
    Logger.error("Chart range fetch failed: #{inspect(reason)}")
    {:noreply, socket}
  end

  def handle_async(:reload_calibration_plot, {:ok, calib}, socket) do
    socket =
      assign(socket, :calibration_plot, AsyncResult.ok(socket.assigns.calibration_plot, calib))

    socket =
      if socket.assigns.display_mode == :calibration and Map.get(calib, :plot_available) do
        push_event(socket, "echarts-data-#{socket.assigns.id}-calib", %{option: calib.option})
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_async(:reload_calibration_plot, {:exit, reason}, socket) do
    {:noreply,
     assign(
       socket,
       :calibration_plot,
       AsyncResult.failed(socket.assigns.calibration_plot, {:exit, reason})
     )}
  end

  defp tab_class(true), do: "bg-base-300 text-base-content font-semibold"
  defp tab_class(false), do: "text-muted hover:text-base-content hover:bg-base-200"

  @impl true
  def render(assigns) do
    ~H"""
    <div class={["flex min-w-0 flex-1 flex-col", assigns[:class]]}>
      <div :if={@display_mode != :empty} class="mb-1.5 flex flex-wrap items-center gap-1">
        <button
          :if={@plottable}
          class={["rounded px-2 py-1 text-xs transition-colors", tab_class(@display_mode == :graph)]}
          phx-click={JS.push("set-display-mode", value: %{mode: "graph"}, target: @myself)}
        >
          Graph
        </button>
        <button
          class={["rounded px-2 py-1 text-xs transition-colors", tab_class(@display_mode == :table)]}
          phx-click={JS.push("set-display-mode", value: %{mode: "table"}, target: @myself)}
        >
          Table
        </button>
        <button
          :if={@interface_class == "calibratable"}
          class={[
            "rounded px-2 py-1 text-xs transition-colors",
            tab_class(@display_mode == :calibration)
          ]}
          phx-click={JS.push("set-display-mode", value: %{mode: "calibration"}, target: @myself)}
        >
          Calibration
        </button>
        <span class="flex-1"></span>
        <div
          :if={@display_mode == :graph}
          id={"range-buttons-#{@id}"}
          phx-update="ignore"
          class="flex gap-0.5"
        >
        </div>
        <a
          :if={@parameter}
          id={"csv-export-#{@id}"}
          href={"/export/parameter/#{@parameter.id}"}
          download
          class="inline-flex items-center gap-1 rounded border border-line px-1.5 py-0.5 text-[11px] text-muted hover:bg-base-200 hover:text-base-content"
          title={"Download all recorded values of #{@parameter.name} as CSV"}
        >
          <.icon name="hero-arrow-down-tray-micro" class="size-3.5" /> CSV
        </a>
        <button
          :if={@display_mode == :graph}
          id={"rangeslider-btn-#{@id}"}
          class="rounded border border-line px-1.5 py-0.5 text-[11px] text-muted hover:bg-base-200"
          data-chart-id={@id}
          title="Show or hide the time range slider"
          aria-label="Toggle time range slider"
          phx-click={JS.toggle_class("text-ink") |> JS.dispatch("toggle-rangeslider")}
        >
          <.icon name="hero-arrows-right-left-micro" class="size-3.5" />
        </button>
      </div>

      <%= case @display_mode do %>
        <% :graph -> %>
          <%= if @plottable do %>
            <.async_result :let={_plot} assign={@plot}>
              <:loading>
                <div
                  class="flex animate-pulse items-center justify-center rounded-box bg-base-200 text-muted"
                  style={"height: #{@chart_height}px"}
                >
                  Waiting for valid Plot Data...
                </div>
              </:loading>
              <:failed>
                <div class="rounded-box border border-st-error/50 p-3 text-st-error">
                  Could not load the plot.
                </div>
              </:failed>

              <div
                class="rounded-box border border-line bg-base-100 p-1"
                style={"height: #{@chart_height}px"}
              >
                <div id={@id} class="h-full" phx-hook="EChartsChart" phx-update="ignore"></div>
              </div>
            </.async_result>
          <% else %>
            <div class="flex h-24 items-center justify-center rounded-box border border-dashed border-line text-muted">
              Data not plottable
            </div>
          <% end %>
        <% :table -> %>
          <.async_result :let={table_data} assign={@table_data}>
            <:loading>
              <div class="h-40 animate-pulse rounded-box bg-base-200"></div>
            </:loading>
            <:failed>
              <div class="rounded-box border border-st-error/50 p-3 text-st-error">
                Could not load the values.
              </div>
            </:failed>
            <div class="overflow-x-auto rounded-box border border-line text-xs">
              <AshPagify.Components.table
                items={table_data.parameter_values}
                meta={table_data.meta}
                on_sort={JS.push("sort", target: @myself)}
                opts={table_opts()}
                id={"#{@id}-table"}
              >
                <:col :let={parameter_value} label="Time" field={:timestamp}>
                  <span class="font-mono">
                    {parameter_value.timestamp
                    |> DateTime.from_naive!("Etc/UTC")
                    |> DateTime.shift_zone!("Europe/Berlin")
                    |> Calendar.strftime("%d.%m.%Y %H:%M:%S.%f")}
                  </span>
                </:col>
                <:col :let={parameter_value} label="Value" field={:value}>
                  <div class="max-w-[24rem] truncate font-mono">
                    {ParameterValue.get_display_value(parameter_value, @parameter)}
                  </div>
                </:col>
              </AshPagify.Components.table>

              <AshPagify.Components.pagination
                meta={table_data.meta}
                on_paginate={JS.push("paginate", target: @myself)}
                opts={history_pagination_opts()}
              />
            </div>
          </.async_result>
        <% :calibration -> %>
          <.async_result :let={_calib} assign={@calibration_plot}>
            <:loading>
              <div class="flex h-[520px] animate-pulse items-center justify-center rounded-box bg-base-200 text-muted">
                Computing calibration curves...
              </div>
            </:loading>
            <:failed>
              <div class="rounded-box border border-st-error/50 p-3 text-st-error">
                Could not compute the calibration curves.
              </div>
            </:failed>
            <div class="rounded-box border border-line bg-base-100 p-1">
              <div id={"#{@id}-calib"} class="h-[640px]" phx-hook="EChartsChart" phx-update="ignore">
              </div>
            </div>
          </.async_result>
        <% :empty -> %>
          <%!-- nothing to show, e.g. communicator modules without a value --%>
        <% _ -> %>
          <div class="rounded-box border border-dashed border-line p-4 text-muted">
            Unknown display mode
          </div>
      <% end %>
    </div>
    """
  end
end
