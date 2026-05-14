defmodule SecantServiceWeb.Components.HistoryDB do
  use Phoenix.LiveComponent
  import SecantServiceWeb.CoreComponents
  require Logger
  alias SecantService.PlotDB
  alias SecantService.SecNodes.ParameterValue
  alias Phoenix.LiveView.JS

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
    {:ok, socket}
  end

  defp get_parameter(secop_obj) do
    case secop_obj do
      %SecantService.SecNodes.Parameter{} = param ->
        param

      %SecantService.SecNodes.Module{} = module ->
        Enum.find(module.parameters, nil, fn param -> param.name == "value" end)
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
              |> assign_async(:plot, fn -> {:ok, %{plot: PlotDB.init(secop_obj, plot_mode)}} end)

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
        |> assign(:id, assigns.id)
        |> assign(:class, assigns.class)
        |> assign(:parameter, get_parameter(secop_obj))
        |> assign(:secop_obj, secop_obj)
        |> assign(:interface_class, ifclass)
      end

    {:ok, socket}
  end

  def update(%{value_update: value_update_list, parameter: parameter} = _assigns, socket) do
    param_list =
      case socket.assigns.secop_obj do
        %SecantService.SecNodes.Parameter{} = param ->
          [param.name]

        %SecantService.SecNodes.Module{} = module ->
          case module.highest_interface_class do
            "readable" -> ["value"]
            "drivable" -> ["value", "target"]
            "calibratable" -> ["value", "_value_uncalibrated", "target", "_target_calibrated"]
            "communicator" -> []
            "acquisition" -> ["value"]
            _ -> []
          end
      end

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

          push_event(socket, "extend-traces-#{socket.assigns.id}", update_data)
        else
          socket
        end
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("request-plotly-data", %{"id" => chart_id}, %{assigns: assigns} = socket) do
    if String.ends_with?(chart_id, "-calib") do
      calib = assigns.calibration_plot.result

      {:noreply,
       push_event(socket, "plotly-data-#{chart_id}", %{
         data: calib.data,
         layout: calib.layout,
         config: calib.config
       })}
    else
      {:noreply,
       push_event(socket, "plotly-data-#{socket.assigns.id}", %{
         data: assigns.plot.result.data,
         layout: assigns.plot.result.layout,
         config: assigns.plot.result.config
       })}
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
              |> assign_async(:plot, fn -> {:ok, %{plot: PlotDB.init(secop_obj, plot_mode)}} end)
            else
              socket
            end

          # Eagerly push already-loaded plot data so it is batched with the DOM
          # diff. LiveView guarantees push_events fire only after the diff is
          # applied (hook mounted, handleEvent registered), avoiding the round-
          # trip race between pushEventTo → request-plotly-data → push_event.
          case socket.assigns[:plot] do
            %{ok?: true, result: plot} ->
              push_event(socket, "plotly-data-#{socket.assigns.id}", %{
                data: plot.data,
                layout: plot.layout,
                config: plot.config
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
  def render(assigns) do
    ~H"""
    <div class={["flex flex-col flex-1", assigns[:class]]}>
      <%= if @display_mode != :empty  do %>
        <div class="flex space-x-2 mb-2">
          <button
            class={[
              "btn btn-neutral",
              @display_mode == :graph &&
                "btn-active btn-primary",
              @plottable == false &&
                "btn-disabled"
            ]}
            phx-click={JS.push("set-display-mode", value: %{mode: "graph"}, target: @myself)}
          >
            <div class="flex items-center">
              <.icon name="hero-chart-bar-solid" class="h-5 w-5 flex-none mr-1" /> Graph
            </div>
          </button>

          <button
            class={[
              "btn btn-neutral",
              @display_mode == :table &&
                "btn-active btn-primary"
            ]}
            phx-click={JS.push("set-display-mode", value: %{mode: "table"}, target: @myself)}
          >
            <div class="flex items-center">
              <.icon name="hero-table-cells-solid" class="h-5 w-5 flex-none mr-1" /> Table
            </div>
          </button>
          <%= if @interface_class == "calibratable" do %>
            <button
              class={[
                "btn btn-neutral",
                @display_mode == :calibration &&
                  "btn-active btn-primary",
                @plottable == false &&
                  "btn-disabled"
              ]}
              phx-click={JS.push("set-display-mode", value: %{mode: "calibration"}, target: @myself)}
            >
              <div class="flex items-center">
                <.icon name="hero-calculator-solid" class="h-5 w-5 flex-none mr-1" />
                Calibration Coefficients
              </div>
            </button>
          <% end %>

          <%= if @display_mode == :graph do %>
            <button
              id={"rangeslider-btn-#{@id}"}
              class="btn btn-outline btn-primary"
              data-chart-id={@id}
              phx-click={
                JS.toggle_class("btn-active")
                |> JS.dispatch("toggle-rangeslider")
              }
            >
              <div class="flex items-center">
                <.icon name="hero-arrows-right-left-solid" class="h-5 w-5 flex-none mr-1" />
                Range Slider
              </div>
            </button>
          <% end %>
        </div>
      <% end %>

      <%= case @display_mode do %>
        <% :graph -> %>
          <%= if @plottable do %>
            <.async_result :let={_plot} assign={@plot}>
              <:loading>
                <div class="flex flex-1 h-[340px] animate-pulse items-center justify-center text-center bg-gray-300 p-4 rounded-lg">
                  <span class="text-gray-700">Waiting for valid Plot Data...</span>
                </div>
              </:loading>
              <:failed>
                ERROR
              </:failed>

              <div class="flex-1 bg-gray-300 p-1 rounded-lg">
                <div
                  id={@id}
                  class=""
                  phx-hook="PlotlyChart"
                  phx-update="ignore"
                >
                </div>
              </div>
            </.async_result>
          <% else %>
            <div class="flex items-center justify-center h-[340px] text-center bg-gray-300 p-4 rounded-lg">
              <span class="text-gray-800">Data not plottable</span>
            </div>
          <% end %>
        <% :table -> %>
          <.async_result :let={table_data} assign={@table_data}>
            <:loading>
              <div class="animate-pulse w-full border-collapse border border-slate-300 dark:border-slate-600 text-gray-700 dark:text-gray-200">
                <table class="w-full">
                  <thead class="p-2 bg-gray-50 dark:bg-gray-800 border border-slate-300 dark:border-slate-600">
                    <tr>
                      <th class="p-2">Time</th>
                      <th class="p-2">Value</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for _i <- 1..10 do %>
                      <tr class="border-b border-gray-200">
                        <td class="p-2">
                          <div class="h-6 bg-gray-400 rounded w-28"></div>
                        </td>
                        <td class="p-2">
                          <div class="h-6 bg-gray-400 rounded w-20"></div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </:loading>
            <:failed>
              ERROR
            </:failed>
            <div class="card bg-neutral rounded-lg  p-2">
              <AshPagify.Components.table
                items={table_data.parameter_values}
                meta={table_data.meta}
                on_sort={JS.push("sort", target: @myself)}
                opts={table_opts()}
                id={"#{@id}-table"}
              >
                <:col :let={parameter_value} label="Time" field={:timestamp}>
                  {parameter_value.timestamp
                  |> DateTime.from_naive!("Etc/UTC")
                  |> DateTime.shift_zone!("Europe/Berlin")
                  |> Calendar.strftime("%d.%m.%Y %H:%M:%S.%f")}
                </:col>
                <:col :let={parameter_value} label="Value" field={:value}>
                  <div class="w-full max-w-1/2 font-mono truncate">
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
              <div class="flex flex-1 h-[520px] animate-pulse items-center justify-center text-center bg-gray-300 p-4 rounded-lg">
                <span class="text-gray-700">Computing calibration curves...</span>
              </div>
            </:loading>
            <:failed>
              ERROR
            </:failed>
            <div class="flex-1 bg-gray-300 p-1 rounded-lg">
              <div
                id={"#{@id}-calib"}
                phx-hook="PlotlyChart"
                phx-update="ignore"
              >
              </div>
            </div>
          </.async_result>
        <% :empty -> %>
          <!-- Nothing is rendered here, for example communicator modules
            that do not have a main param like value -->

        <% _ -> %>
          <div class="flex items-center justify-center h-full text-center bg-gray-300 p-4 rounded-lg">
            <span class="text-gray-800">Unknown display mode</span>
          </div>
      <% end %>
    </div>
    """
  end
end
