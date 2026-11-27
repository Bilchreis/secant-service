defmodule SecantServiceWeb.Components.HistoryDB do
  use Phoenix.LiveComponent
  import SecantServiceWeb.CoreComponents
  require Logger
  alias SecantService.SecNodes
  alias SecantService.PlotDB
  alias SecantService.PlotDB.Bands
  alias SecantService.PlotDB.Builders
  alias SecantService.PlotDB.Gaps
  alias SecantService.PlotDB.History
  alias SecantService.PlotDB.DTypes.ArrayLatest
  alias SecantService.SecNodes.Reading.Storage
  alias Phoenix.LiveView.JS
  alias Phoenix.LiveView.AsyncResult

  defp get_tabledata(secop_obj, params \\ %{}) do
    parameter = get_parameter(secop_obj)

    # Ensure default pagination parameters are set
    params_with_defaults = Map.merge(%{limit: 20, page: 1, order_by: ["-timestamp"]}, params)

    case SecNodes.browse_readings(parameter, params_with_defaults) do
      {:ok, {parameter_values, meta}} ->
        {:ok, %{table_data: %{parameter_values: parameter_values, meta: meta}}}

      {:error, reason} ->
        Logger.error("Error fetching parameter values: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # earliest time a zoomed window may start: year 0, as for the history
  # actions (a node can stamp readings before 1970)
  @earliest_window_ms -62_167_219_200_000

  @impl true
  def mount(socket) do
    {:ok, socket |> assign(:chart_height, 340) |> assign(:gap_events, [])}
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

    array_len =
      updates_list
      |> Enum.map(&Map.get(&1, :arrayLen))
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    case array_len do
      nil -> %{seriesUpdates: series_updates}
      len -> %{seriesUpdates: series_updates, arrayLen: len}
    end
  end

  # Rebuild the plot as the latest-reading plot. The old chart stays up
  # meanwhile (`:rebuilding_plot` holds back updates into it); a newer
  # rebuild replaces a running one.
  defp rebuild_as_latest(socket, param, latest_fun) do
    socket
    |> assign(:rebuilding_plot, true)
    |> assign(:rebuild_param, param)
    |> cancel_async(:load_plot)
    # heatmap history still loading would only go into the replaced chart
    |> cancel_async(:fetch_chart_range)
    |> start_async(:load_plot, fn -> ArrayLatest.plot(param, latest_fun.()) end)
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

  # Recording of the node stopped or resumed (`SecantService.PlotCache`):
  # a live plot that has gaps (number lines, numeric arrays) opens or
  # closes a gap there. Events that arrive while the plot loads are pushed
  # after it.
  def update(%{recording: {kind, ms}}, socket) do
    event = %{
      kind: if(kind == :stopped, do: "open", else: "close"),
      ms: ms,
      # when the server sent it, to order it against loaded gaps
      at: System.os_time(:millisecond)
    }

    socket =
      cond do
        socket.assigns[:plot_mode] != :live or not socket.assigns[:plottable] ->
          socket

        not socket.assigns.plot.ok? or socket.assigns[:rebuilding_plot] ->
          update(socket, :gap_events, &(&1 ++ [event]))

        match?(%{option: %{_gaps: _}}, socket.assigns.plot.result) ->
          push_event(socket, "gap-chart-#{socket.assigns.id}", event)

        true ->
          socket
      end

    {:ok, socket}
  end

  def update(%{value_update: value_update_list, parameter: parameter} = _assigns, socket) do
    # a historical plot draws what is stored; it takes no live readings
    socket =
      if socket.assigns.plottable and socket.assigns.plot_mode == :live and
           socket.assigns.plot.ok? and parameter in PlotDB.param_list(socket.assigns.secop_obj) do
        datapoints =
          for [value, %{t: timestamp}] <- value_update_list, do: {value, trunc(timestamp * 1000)}

        live_update(socket, parameter, datapoints)
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

  defp live_update(socket, _parameter, []), do: socket

  defp live_update(socket, parameter, datapoints) do
    plot = socket.assigns.plot.result

    cond do
      # the array got too long for the heatmap: rebuild as latest-reading
      # plot. The old chart stays up meanwhile; a newer long reading
      # restarts the rebuild (only the last start_async result is used).
      latest = PlotDB.outgrown(plot, parameter, datapoints) ->
        param = resolve_param(socket.assigns.secop_obj, parameter)
        rebuild_as_latest(socket, param, fn -> latest end)

      # while rebuilding, a newer reading of the rebuilt parameter
      # restarts the rebuild from it; nothing goes into the old heatmap
      socket.assigns[:rebuilding_plot] ->
        case {socket.assigns[:rebuild_param], Enum.filter(datapoints, &is_list(elem(&1, 0)))} do
          {%{name: ^parameter} = param, [_ | _] = readings} ->
            rebuild_as_latest(socket, param, fn -> List.last(readings) end)

          _ ->
            socket
        end

      true ->
        update = PlotDB.trace_updates(plot, datapoints, parameter)
        push_event(socket, "extend-chart-#{socket.assigns.id}", update)
    end
  end

  @impl true
  # Time slider of a long-array plot: load the reading at (or just before) `t`.
  def handle_event("fetch-array-reading", %{"t" => t}, socket) when is_integer(t) do
    with %AsyncResult{ok?: true, result: %{plot_type: :array_latest, _array_param: name}} <-
           socket.assigns.plot,
         %{} = param <- resolve_param(socket.assigns.secop_obj, name) do
      {:noreply,
       start_async(socket, :array_reading, fn ->
         case ArrayLatest.fetch_at(param, t) do
           nil -> nil
           reading -> Map.put(ArrayLatest.snapshot(reading), :requested, t)
         end
       end)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("fetch-array-reading", _params, socket), do: {:noreply, socket}

  # the chart is about to be replaced by the latest-reading plot
  def handle_event("fetch-chart-range", _params, %{assigns: %{rebuilding_plot: true}} = socket),
    do: {:noreply, socket}

  # A live chart's range got wider: the readings from `from` (nil: the first
  # one) up to `to`, where its buffer starts, thinned out like the history
  # view's (see SecantService.PlotDB.History), so a wide range stays light.
  def handle_event(
        "fetch-chart-range",
        %{"from" => from_ms, "to" => to_ms} = params,
        %{assigns: %{plot: %AsyncResult{ok?: true, result: plot}}} = socket
      )
      when (is_number(from_ms) or is_nil(from_ms)) and is_number(to_ms) do
    req = params["req"]

    secop_obj = socket.assigns.secop_obj
    latest = latest_window_ms()
    from_ms = from_ms && from_ms |> max(@earliest_window_ms) |> min(latest) |> trunc()
    to_ms = to_ms |> max(from_ms || @earliest_window_ms) |> min(latest) |> trunc()

    socket =
      socket
      # an answer for the range clicked before is of no use
      |> cancel_async(:fetch_chart_range)
      |> assign(:range_req, req)
      |> start_async(:fetch_chart_range, fn ->
        lines = drawn_lines(secop_obj, plot)

        lines
        |> Enum.reduce_while({[], false, nil}, fn %{param: param}, {acc, aggregated, bucket} ->
          window = SecNodes.history_window!(param.id, from_ms, to_ms)
          datapoints = Enum.zip(window.values, window.timestamps)

          # older readings longer than the heatmap carries: switch to the
          # latest-reading plot instead of backfilling them
          if PlotDB.outgrown(plot, param.name, datapoints) do
            {:halt, {:rebuild, param}}
          else
            {:cont,
             {[PlotDB.trace_updates(plot, datapoints, param.name) | acc],
              aggregated or window.aggregated, max_bucket(bucket, window.bucket_ms)}}
          end
        end)
        |> case do
          {:rebuild, param} ->
            {:rebuild, param}

          # `req`: the browser's, so it can drop answers to earlier clicks;
          # `aggregated`: thinned out, so not every reading is in the buffers
          {updates, aggregated, bucket_ms} ->
            updates
            |> Enum.reverse()
            |> merge_trace_updates()
            |> Map.merge(%{
              from: from_ms,
              to: to_ms,
              aggregated: aggregated,
              bucket_ms: bucket_ms,
              req: req
            })
            |> Map.merge(Gaps.reply(plot, lines, {from_ms, to_ms}))
        end
      end)

    {:noreply, socket}
  end

  def handle_event("fetch-chart-range", _params, socket), do: {:noreply, socket}

  # The range got narrower: a wider one still being fetched is of no use.
  def handle_event("cancel-chart-range", _params, socket),
    do: {:noreply, cancel_async(socket, :fetch_chart_range)}

  # A zoomed historical chart asks for the readings of the window it shows.
  # Long windows come back thinned out, short ones with every reading, and
  # with `envelope: true` as min/mean/max envelopes where the aggregates
  # cover them (see SecantService.PlotDB.History).
  def handle_event(
        "fetch-chart-window",
        %{"from" => from_ms, "to" => to_ms, "req" => req} = params,
        %{assigns: %{plot: %AsyncResult{ok?: true, result: %{option: %{_windowFetch: _}} = plot}}} =
          socket
      )
      when is_number(from_ms) and is_number(to_ms) and from_ms <= to_ms do
    secop_obj = socket.assigns.secop_obj
    envelope = envelope_flag(params)
    gen = gen(params)
    # the window comes from the browser: keep it to dates the history
    # actions accept (year 0 up to a day from now), so a forged one can't
    # crash the fetch
    latest = latest_window_ms()
    from_ms = from_ms |> max(@earliest_window_ms) |> min(latest)
    to_ms = to_ms |> max(from_ms) |> min(latest)

    socket =
      socket
      # only the newest window matters: stop a fetch still running
      |> cancel_async(:fetch_chart_window)
      |> assign(:window_req, req)
      |> start_async(:fetch_chart_window, fn ->
        lines = drawn_lines(secop_obj, plot)

        windows =
          for line <- lines do
            args = if envelope and Bands.eligible?(line), do: %{envelope: true}, else: %{}
            window = SecNodes.history_window!(line.param.id, trunc(from_ms), trunc(to_ms), args)
            {values, timestamps} = held_window(line, from_ms, window)
            {line, values, timestamps, Map.take(window, [:aggregated, :bucket_ms, :envelope])}
          end

        # longer readings than the heatmap carries: the latest-reading plot
        case outgrown_param(windows, plot) do
          nil ->
            reply = window_reply(windows, plot)

            reply
            |> Map.merge(%{from: from_ms, to: to_ms, req: req, gen: gen, envelope: envelope})
            |> Map.merge(Gaps.reply(plot, lines, {trunc(from_ms), trunc(to_ms)}))

          param ->
            {:rebuild, param}
        end
      end)

    {:noreply, socket}
  end

  def handle_event("fetch-chart-window", _params, socket), do: {:noreply, socket}

  # The envelope was switched on or off: the whole recording again, as on
  # the first load, in the chosen mode. Runs on its own task, so a window
  # fetch sent meanwhile neither cancels it nor is cancelled by it.
  def handle_event(
        "fetch-chart-overview",
        params,
        %{assigns: %{plot: %AsyncResult{ok?: true, result: %{option: %{_windowFetch: _}} = plot}}} =
          socket
      ) do
    secop_obj = socket.assigns.secop_obj
    envelope = envelope_flag(params)
    gen = gen(params)

    socket =
      socket
      |> assign(:overview_gen, gen)
      |> cancel_async(:fetch_chart_overview)
      |> start_async(:fetch_chart_overview, fn ->
        lines = drawn_lines(secop_obj, plot)

        windows =
          for line <- lines do
            {values, timestamps, resolution} =
              if line.setpoint? do
                Builders.fetch_held_param_window(line.param, :historical)
              else
                Builders.fetch_param_window(line.param, :historical,
                  envelope: envelope and Bands.eligible?(line)
                )
              end

            {line, values, timestamps, resolution}
          end

        # longer readings than the heatmap carries: the latest-reading plot
        case outgrown_param(windows, plot) do
          nil ->
            reply = window_reply(windows, plot)

            reply
            |> Map.merge(%{gen: gen, envelope: envelope})
            |> Map.merge(Gaps.reply(plot, lines, {nil, nil}, fallback?: true))

          param ->
            {:rebuild, param}
        end
      end)

    {:noreply, socket}
  end

  def handle_event("fetch-chart-overview", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("request-chart-data", %{"id" => chart_id}, %{assigns: assigns} = socket) do
    # Only push when a chart option actually exists — a plot result may be a
    # not_plottable map without an :option key.
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
  def handle_event("set-display-mode", %{"mode" => mode}, socket)
      when mode in ["graph", "table", "calibration"] do
    display_mode = String.to_existing_atom(mode)
    secop_obj = socket.assigns.secop_obj

    socket =
      case display_mode do
        # already shown: nothing to do (a live plot would lose its buffers),
        # unless it failed to load
        :graph
        when socket.assigns.display_mode == :graph and
               socket.assigns.plot.failed in [nil, false] ->
          socket

        # A live plot is loaded again: the readings it got while the table
        # was shown went into a chart that is gone.
        :graph when socket.assigns.plot == nil or socket.assigns.plot_mode == :live ->
          plot_mode = socket.assigns.plot_mode

          socket
          |> assign(:plot, AsyncResult.loading())
          |> cancel_async(:fetch_chart_range)
          |> start_async(:load_plot, fn -> PlotDB.init(secop_obj, plot_mode) end)

        # Eagerly push already-loaded plot data so it is batched with the DOM
        # diff. LiveView guarantees push_events fire only after the diff is
        # applied (hook mounted, handleEvent registered), avoiding the round-
        # trip race between pushEventTo → request-chart-data → push_event.
        :graph ->
          case socket.assigns.plot do
            %{ok?: true, result: %{option: option}} ->
              push_event(socket, "echarts-data-#{socket.assigns.id}", %{option: option})

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
      end

    {:noreply, assign(socket, :display_mode, display_mode)}
  end

  def handle_event("set-display-mode", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:load_plot, {:ok, plot}, socket) do
    height = chart_height(plot, socket.assigns.base_height)
    plot = SecantService.PlotDB.DTypes.Struct.fit_height(plot, height)

    socket =
      socket
      |> assign(:plot, AsyncResult.ok(socket.assigns.plot, plot))
      |> assign(:chart_height, height)
      |> assign(:rebuilding_plot, false)

    socket =
      if socket.assigns.display_mode == :graph and Map.get(plot, :plottable) and
           Map.get(plot, :option) do
        push_event(socket, "echarts-data-#{socket.assigns.id}", %{
          option: plot.option
        })
      else
        socket
      end

    {:noreply, push_gap_events(socket, plot)}
  end

  def handle_async(:load_plot, {:exit, reason}, socket) do
    socket = assign(socket, :rebuilding_plot, false)
    {:noreply, assign(socket, :plot, AsyncResult.failed(socket.assigns.plot, {:exit, reason}))}
  end

  def handle_async(:array_reading, {:ok, nil}, socket), do: {:noreply, socket}

  def handle_async(:array_reading, {:ok, snapshot}, socket) do
    {:noreply, push_event(socket, "array-reading-#{socket.assigns.id}", snapshot)}
  end

  def handle_async(:array_reading, {:exit, reason}, socket) do
    Logger.warning("Loading array reading failed: #{inspect(reason)}")
    {:noreply, socket}
  end

  def handle_async(:fetch_chart_range, {:ok, {:rebuild, param}}, socket) do
    {:noreply, rebuild_as_latest(socket, param, fn -> ArrayLatest.fetch_latest(param) end)}
  end

  def handle_async(:fetch_chart_range, {:ok, update_data}, socket) do
    {:noreply, push_event(socket, "prepend-chart-data-#{socket.assigns.id}", update_data)}
  end

  # cancelled by rebuild_as_latest/3
  def handle_async(:fetch_chart_range, {:exit, {:shutdown, :cancel}}, socket),
    do: {:noreply, socket}

  def handle_async(:fetch_chart_range, {:exit, reason}, socket) do
    Logger.error("Chart range fetch failed: #{inspect(reason)}")

    {:noreply,
     push_event(socket, "range-chart-error-#{socket.assigns.id}", %{
       req: socket.assigns[:range_req]
     })}
  end

  def handle_async(:fetch_chart_window, {:ok, {:rebuild, param}}, socket) do
    {:noreply, rebuild_as_latest(socket, param, fn -> ArrayLatest.fetch_latest(param) end)}
  end

  def handle_async(:fetch_chart_window, {:ok, window}, socket) do
    {:noreply, push_event(socket, "window-chart-data-#{socket.assigns.id}", window)}
  end

  # replaced by a newer window, or by rebuild_as_latest/3
  def handle_async(:fetch_chart_window, {:exit, {:shutdown, :cancel}}, socket),
    do: {:noreply, socket}

  def handle_async(:fetch_chart_window, {:exit, reason}, socket) do
    Logger.error("Chart window fetch failed: #{inspect(reason)}")

    {:noreply,
     push_event(socket, "window-chart-error-#{socket.assigns.id}", %{
       req: socket.assigns[:window_req]
     })}
  end

  def handle_async(:fetch_chart_overview, {:ok, {:rebuild, param}}, socket) do
    {:noreply, rebuild_as_latest(socket, param, fn -> ArrayLatest.fetch_latest(param) end)}
  end

  def handle_async(:fetch_chart_overview, {:ok, overview}, socket) do
    {:noreply, push_event(socket, "overview-chart-data-#{socket.assigns.id}", overview)}
  end

  # replaced by a newer reload, or by rebuild_as_latest/3
  def handle_async(:fetch_chart_overview, {:exit, {:shutdown, :cancel}}, socket),
    do: {:noreply, socket}

  # the hook goes back to the mode it has loaded
  def handle_async(:fetch_chart_overview, {:exit, reason}, socket) do
    Logger.error("Chart overview reload failed: #{inspect(reason)}")

    {:noreply,
     push_event(socket, "overview-chart-error-#{socket.assigns.id}", %{
       gen: socket.assigns[:overview_gen]
     })}
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

  defp latest_reading_plot?(%AsyncResult{ok?: true, result: %{plot_type: :array_latest}}),
    do: true

  defp latest_reading_plot?(_plot), do: false

  defp utc_ms(%DateTime{} = ts), do: DateTime.to_unix(ts, :millisecond)

  defp utc_ms(%NaiveDateTime{} = ts),
    do: ts |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)

  defp micros(%{microsecond: {us, _precision}}), do: us

  defp tab_class(true), do: "bg-base-300 text-base-content font-semibold"
  defp tab_class(false), do: "text-muted hover:text-base-content hover:bg-base-200"

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"history-#{@id}"} class={["flex min-w-0 flex-1 flex-col", assigns[:class]]}>
      <div :if={@display_mode != :empty} class="mb-1.5 flex flex-wrap items-center gap-1">
        <div role="tablist" aria-label="View" class="flex gap-1">
          <button
            :for={
              {mode, label, shown} <- [
                {:graph, "Graph", @plottable},
                {:table, "Table", true},
                {:calibration, "Calibration", @interface_class == "calibratable"}
              ]
            }
            :if={shown}
            id={"#{@id}-tab-#{mode}"}
            type="button"
            role="tab"
            aria-selected={to_string(@display_mode == mode)}
            class={["rounded px-2 py-1 text-xs transition-colors", tab_class(@display_mode == mode)]}
            phx-click={JS.push("set-display-mode", value: %{mode: mode}, target: @myself)}
          >
            {label}
          </button>
        </div>
        <%!-- Heatmap / Lines switch, filled by the chart hook for array plots --%>
        <div
          :if={@display_mode == :graph}
          id={"array-mode-#{@id}"}
          phx-update="ignore"
          role="group"
          aria-label="Array plot style"
          class="ml-2 flex rounded border border-line p-0.5 empty:hidden"
        >
        </div>
        <%!-- min/mean/max envelope on or off, filled by the chart hook for historical line plots --%>
        <div
          :if={@display_mode == :graph}
          id={"envelope-toggle-#{@id}"}
          phx-update="ignore"
          class="flex empty:hidden"
        >
        </div>
        <span class="flex-1"></span>
        <%!-- "min/max per 15 min" or "every reading", filled by the chart hook --%>
        <span
          :if={@display_mode == :graph}
          id={"resolution-#{@id}"}
          phx-update="ignore"
          class="mr-1 font-mono text-[11px] text-muted empty:hidden"
        ></span>
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
        <%!-- a long array's latest reading is drawn over its index, not time --%>
        <button
          :if={@display_mode == :graph and not latest_reading_plot?(@plot)}
          id={"rangeslider-btn-#{@id}"}
          type="button"
          class="rounded border border-line px-1.5 py-0.5 text-[11px] text-muted transition-colors hover:bg-base-200 aria-pressed:bg-base-300 aria-pressed:text-base-content"
          data-chart-id={@id}
          title="Show or hide the time range slider"
          aria-label="Time range slider"
          aria-pressed="false"
          phx-click={
            JS.toggle_attribute({"aria-pressed", "true", "false"})
            |> JS.dispatch("toggle-rangeslider")
          }
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
                  Loading plot…
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
              <%!-- time slider of long-array plots, filled by the chart hook --%>
              <div
                id={"array-scrub-#{@id}"}
                phx-update="ignore"
                class="mt-1.5 flex items-center gap-2 empty:hidden"
              >
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
            <div
              id={"#{@id}-table-wrap"}
              phx-hook=".LocalTimes"
              class="overflow-x-auto rounded-box border border-line text-xs"
            >
              <AshPagify.Components.table
                items={table_data.parameter_values}
                meta={table_data.meta}
                on_sort={JS.push("sort", target: @myself)}
                opts={table_opts()}
                id={"#{@id}-table"}
              >
                <:col :let={parameter_value} label="Time" field={:timestamp}>
                  <%!-- UTC until the hook shows it in the browser's time zone, like the charts --%>
                  <span
                    class="font-mono"
                    data-utc-ms={utc_ms(parameter_value.timestamp)}
                    data-us={micros(parameter_value.timestamp)}
                  >
                    {Calendar.strftime(parameter_value.timestamp, "%d.%m.%Y %H:%M:%S.%f")} UTC
                  </span>
                </:col>
                <:col :let={parameter_value} label="Value" field={Storage.column(@parameter)}>
                  <div class="max-w-[24rem] truncate font-mono">
                    {Storage.display_value(parameter_value, @parameter)}
                  </div>
                </:col>
              </AshPagify.Components.table>

              <AshPagify.Components.pagination
                meta={table_data.meta}
                on_paginate={JS.push("paginate", target: @myself)}
                opts={history_pagination_opts()}
              />
              <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTimes">
                // Reading times in the browser's time zone, as the charts show
                // them: dd.mm.yyyy hh:mm:ss.ffffff.
                const pad = (n, w = 2) => String(n).padStart(w, "0");
                const show = (root) => {
                  root.querySelectorAll("[data-utc-ms]").forEach((el) => {
                    const d = new Date(Number(el.dataset.utcMs));
                    if (isNaN(d)) return;
                    el.textContent =
                      `${pad(d.getDate())}.${pad(d.getMonth() + 1)}.${d.getFullYear()} ` +
                      `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(el.dataset.us, 6)}`;
                  });
                };
                export default {
                  mounted() { show(this.el); },
                  updated() { show(this.el); },
                };
              </script>
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

  # The overview pins a parameter's reading from before the plot start to
  # that start, and the chart drops overview points inside a detail window:
  # a window from the start holds that reading again. A setpoint holds until
  # the next one, so every window starts with the setpoint in force.
  defp latest_window_ms, do: System.os_time(:millisecond) + :timer.hours(24)

  # Only a literal `true` switches the envelope on: the event comes from the
  # browser.
  defp envelope_flag(%{"envelope" => true}), do: true
  defp envelope_flag(_params), do: false

  defp gen(%{"gen" => gen}) when is_integer(gen), do: gen
  defp gen(_params), do: nil

  # One reply for a plot's windows: their series updates, band payloads,
  # resolution and array width. `windows` are `{line, values, timestamps,
  # resolution}`, the resolution carrying the window's `envelope`.
  defp window_reply(windows, plot) do
    {updates, envelopes} =
      windows
      |> Enum.map(fn {line, values, timestamps, resolution} ->
        update = PlotDB.trace_updates(plot, Enum.zip(values, timestamps), line.param.name)
        {update, Bands.payload(plot.option, line.series, resolution[:envelope])}
      end)
      |> Enum.unzip()

    envelopes = Enum.reject(envelopes, &is_nil/1)

    windows
    |> Enum.map(&elem(&1, 3))
    |> History.coarsest()
    |> Map.merge(merge_trace_updates(updates))
    |> Map.merge(%{
      envelopes: envelopes,
      envelope_bucket_ms: envelopes |> Enum.map(& &1.bucket_ms) |> Enum.max(fn -> nil end)
    })
  end

  # the first parameter whose window holds an array longer than the heatmap
  # carries
  defp outgrown_param(windows, plot) do
    Enum.find_value(windows, fn {%{param: param}, values, timestamps, _} ->
      PlotDB.outgrown(plot, param.name, Enum.zip(values, timestamps)) && param
    end)
  end

  # the recording events kept while the plot loaded, for a plot with gaps
  defp push_gap_events(socket, %{option: %{_gaps: _}}) do
    socket.assigns.gap_events
    |> Enum.reduce(socket, &push_event(&2, "gap-chart-#{socket.assigns.id}", &1))
    |> assign(:gap_events, [])
  end

  defp push_gap_events(socket, _plot), do: assign(socket, :gap_events, [])

  # The lines of `secop_obj` the plot draws: a heatmap draws only the
  # value, so an undrawn target must not set the resolution of a reply (nor
  # the width its gaps are judged at). Plots without `lines` (the
  # latest-reading plot) use all of them.
  defp drawn_lines(secop_obj, plot) do
    lines = PlotDB.lines(secop_obj)

    case Map.get(plot, :lines) do
      %{} = drawn -> Enum.filter(lines, &Map.has_key?(drawn, &1.param.name))
      nil -> lines
    end
  end

  defp max_bucket(nil, bucket), do: bucket
  defp max_bucket(bucket, nil), do: bucket
  defp max_bucket(a, b), do: max(a, b)

  defp held_window(%{param: param} = line, from_ms, window) do
    if line.setpoint? or from_ms <= Builders.plot_start_ms(param) do
      Builders.hold_from(param, from_ms, window.values, window.timestamps)
    else
      {window.values, window.timestamps}
    end
  end
end
