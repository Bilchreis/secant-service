defmodule SecantService.PlotDB.Builders do
  alias SecantService.SecNodes.ParameterValue
  alias SecantService.SecNodes.Parameter
  alias SEC_Node_Statem
  require Logger

  @markersize 5

  # Mirrors the color_lut in ParameterValueDisplay, same order, Tailwind-500 hex equivalents.
  # Index via rem(integer_value, length(@enum_colors)) — identical to the display component.
  @enum_colors [
    "#ef4444", "#22c55e", "#3b82f6", "#eab308", "#a855f7",
    "#ec4899", "#6366f1", "#f97316", "#14b8a6", "#06b6d4",
    "#10b981", "#84cc16", "#f59e0b", "#f43f5e", "#8b5cf6",
    "#d946ef", "#0ea5e9", "#64748b", "#71717a", "#78716c"
  ]

  # ---------------------------------------------------------------------------
  # Parameter helpers
  # ---------------------------------------------------------------------------

  def find_param(module, name) do
    Enum.find(module.parameters, &(&1.name == name))
  end

  # ---------------------------------------------------------------------------
  # Data fetching
  # ---------------------------------------------------------------------------

  def fetch_param_data(param) do
    get_values(param)
    |> ParameterValue.extract_value_timestamp_lists(param)
    |> read_from_device_if_empty(param.id)
  end

  defp get_values(parameter) do
    ParameterValue.get_resource_module(parameter)
    |> Ash.Query.for_read(:for_parameter, %{parameter_id: parameter.id})
    |> Ash.read!()
  end

  defp read_from_device_if_empty({_value_val, _value_ts} = readings, param_id) do
    case readings do
      {[], []} ->
        Logger.warning(
          "No values found in DB for param_id: #{param_id}, trying to read from device"
        )

        parameter =
          Parameter
          |> Ash.Query.for_read(:get_with_context, %{id: param_id})
          |> Ash.read_first!()

        read_until_valid(
          parameter.module.sec_node.node_id,
          parameter.module.name,
          parameter.name
        )

      {_, _} ->
        readings
    end
  end

  defp read_until_valid(id, module_name, parameter_name) do
    case SEC_Node_Statem.read(id, module_name, parameter_name) do
      {:reply, _r_mod, _r_para, [val, %{t: ts}]} ->
        val = val |> Jason.encode!() |> Jason.decode!()

        secs = trunc(ts)
        usecs = trunc((ts - secs) * 1_000_000)
        {:ok, dt} = DateTime.from_unix(secs)
        ts = %{dt | microsecond: {usecs, 6}} |> DateTime.to_unix(:millisecond)

        {[val], [ts]}

      {:error, :read, _specifier, _error_class, error_text, _error_dict} ->
        Logger.warning("Read failed: #{error_text}, retrying...")
        Process.sleep(10_000)
        read_until_valid(id, module_name, parameter_name)

      other ->
        Logger.warning("Unexpected response: #{inspect(other)}, retrying...")
        Process.sleep(20_000)
        read_until_valid(id, module_name, parameter_name)
    end
  end

  # ---------------------------------------------------------------------------
  # Series builders
  # ---------------------------------------------------------------------------

  def scalar_line_series(name, ts_list, val_list) do
    %{
      name: name,
      type: "line",
      data: Enum.zip_with(ts_list, val_list, &[&1, &2]),
      symbol: "circle",
      symbolSize: @markersize,
      large: true,
      largeThreshold: 2000
    }
  end

  def enum_series(name, ts_list, val_list, members, y_val \\ 0) do
    int_to_name = Map.new(members, fn {k, v} -> {v, k} end)
    n = length(@enum_colors)

    data =
      Enum.zip_with(ts_list, val_list, fn ts, v ->
        mn = Map.get(int_to_name, v, to_string(v))
        %{value: [ts, y_val], name: "#{mn} (#{v})", itemStyle: %{color: Enum.at(@enum_colors, rem(v, n))}}
      end)

    %{
      name: name,
      type: "line",
      step: "end",
      data: data,
      symbol: "roundRect",
      symbolSize: [6, 24],
      lineStyle: %{color: "#666", width: 24, opacity: 0.2}
    }
  end

  def heatmap_series(ts_list, val_list) do
    data =
      Enum.flat_map(Enum.zip(ts_list, val_list), fn {ts, arr} ->
        arr |> Enum.with_index() |> Enum.map(fn {v, i} -> [ts, i, v] end)
      end)

    %{
      type: "scatter",
      data: data,
      symbol: "rect",
      symbolSize: 8,
      encode: %{x: 0, y: 1},
      progressive: 0
    }
  end

  # ---------------------------------------------------------------------------
  # Option assemblers
  # ---------------------------------------------------------------------------

  def timeseries_option(series, unit, mode, legend_selected \\ %{}) do
    base = %{
      backgroundColor: "transparent",
      legend: %{orient: "vertical", right: 0, top: "center"},
      grid: %{top: 10, bottom: 40, left: 60, right: 80},
      xAxis: %{type: "time"},
      yAxis: %{type: "value", name: unit || ""},
      series: series
    }

    base =
      if map_size(legend_selected) > 0 do
        Map.update!(base, :legend, &Map.put(&1, :selected, legend_selected))
      else
        base
      end

    if mode == :historical do
      base
    else
      buttons = range_buttons()
      active = 1
      now_ms = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
      {x_min, x_max} = compute_range(Enum.at(buttons, active), now_ms)

      base
      |> Map.put(:xAxis, %{type: "time", min: x_min, max: x_max})
      |> Map.put(:_rangeButtons, buttons)
      |> Map.put(:_activeButton, active)
    end
  end

  def enum_timeseries_option(series, members, _param_name, mode, y_categories \\ nil) do
    n = length(@enum_colors)

    sorted_members = Enum.sort_by(members, fn {_name, val} -> val end)

    # One ghost line series per enum member — empty data, exists only for the legend.
    legend_series =
      Enum.map(sorted_members, fn {name, val} ->
        color = Enum.at(@enum_colors, rem(val, n))
        %{
          name: "#{name} (#{val})",
          type: "line",
          data: [],
          symbol: "none",
          lineStyle: %{color: color, width: 4},
          itemStyle: %{color: color}
        }
      end)

    # Only show enum-member ghost series in the legend (not "value"/"target" series names).
    legend_names = Enum.map(sorted_members, fn {name, val} -> "#{name} (#{val})" end)

    # int → {name, color} for live-update conversion
    int_to_info = Map.new(members, fn {k, v} -> {to_string(v), %{name: k, color: Enum.at(@enum_colors, rem(v, n))}} end)

    y_axis =
      case y_categories do
        nil ->
          %{type: "value", min: -1, max: 1, show: false}

        cats ->
          %{type: "category", data: cats, axisTick: %{show: false}, axisLine: %{show: false}}
      end

    base = %{
      backgroundColor: "transparent",
      tooltip: %{trigger: "item", formatter: "{b}"},
      grid: %{top: 10, bottom: 40, left: 20, right: 160, containLabel: true},
      xAxis: %{type: "time"},
      yAxis: y_axis,
      legend: %{orient: "vertical", right: 0, top: "center", data: legend_names},
      series: series ++ legend_series
    }

    base =
      case y_categories do
        nil -> base
        cats ->
          series_y = Map.new(cats, fn c -> {c, c} end)
          Map.put(base, :_enumSeriesY, series_y)
      end

    if mode == :historical do
      base
    else
      buttons = range_buttons()
      active = 1
      now_ms = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
      {x_min, x_max} = compute_range(Enum.at(buttons, active), now_ms)

      base
      |> Map.put(:xAxis, %{type: "time", min: x_min, max: x_max})
      |> Map.put(:_rangeButtons, buttons)
      |> Map.put(:_activeButton, active)
      |> Map.put(:_enumMembers, int_to_info)
    end
  end

  def heatmap_option(series, array_len, unit, mode) do
    _ = unit
    y_max = max(array_len - 1, 0)

    color_scale = [
      "#313695",
      "#4575b4",
      "#74add1",
      "#abd9e9",
      "#e0f3f8",
      "#ffffbf",
      "#fee090",
      "#fdae61",
      "#f46d43",
      "#d73027",
      "#a50026"
    ]

    base = %{
      animation: false,
      backgroundColor: "transparent",
      grid: %{top: 10, bottom: 40, left: 60, right: 100},
      xAxis: %{type: "time"},
      yAxis: %{type: "value", min: 0, max: y_max, minInterval: 1},
      visualMap: %{
        calculable: true,
        orient: "vertical",
        right: 0,
        top: "center",
        dimension: 2,
        inRange: %{color: color_scale}
      },
      series: series
    }

    if mode == :historical do
      base
    else
      buttons = range_buttons()
      active = 1
      now_ms = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
      {x_min, x_max} = compute_range(Enum.at(buttons, active), now_ms)

      base
      |> Map.put(:xAxis, %{type: "time", min: x_min, max: x_max})
      |> Map.put(:_rangeButtons, buttons)
      |> Map.put(:_activeButton, active)
      |> Map.put(:_arrayLen, array_len)
    end
  end

  # ---------------------------------------------------------------------------
  # Range helpers (used by option assemblers, exposed for get_trace_updates_batch)
  # ---------------------------------------------------------------------------

  def range_buttons do
    [
      %{label: "1m", step: "minute", count: 1},
      %{label: "10m", step: "minute", count: 10},
      %{label: "30m", step: "minute", count: 30},
      %{label: "1h", step: "hour", count: 1},
      %{label: "1d", step: "day", count: 1},
      %{label: "all", step: "all"}
    ]
  end

  def compute_range(%{step: "all"}, _now_ms), do: {nil, nil}

  def compute_range(%{step: step, count: count}, now_ms) do
    ms =
      case step do
        "minute" -> count * 60 * 1_000
        "hour" -> count * 3_600 * 1_000
        "day" -> count * 86_400 * 1_000
        _ -> 0
      end

    {now_ms - ms, now_ms}
  end
end
