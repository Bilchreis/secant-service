defmodule SecantService.PlotDB.DTypes.Enum do
  @behaviour SecantService.PlotDB.DTypePlot

  alias SecantService.PlotDB.Builders

  # Mirrors the color_lut in ParameterValueDisplay, same order, Tailwind-500 hex equivalents.
  # Index via rem(integer_value, length(@enum_colors)) — identical to the display component.
  @enum_colors [
    "#ef4444", "#22c55e", "#3b82f6", "#eab308", "#a855f7",
    "#ec4899", "#6366f1", "#f97316", "#14b8a6", "#06b6d4",
    "#10b981", "#84cc16", "#f59e0b", "#f43f5e", "#8b5cf6",
    "#d946ef", "#0ea5e9", "#64748b", "#71717a", "#78716c"
  ]

  @impl true
  def supported_type?(%{"type" => "enum"}), do: true
  def supported_type?(_), do: false

  def enum_int_to_info(members) do
    n = length(@enum_colors)
    Map.new(members, fn {k, v} -> {to_string(v), %{name: k, color: Enum.at(@enum_colors, rem(v, n))}} end)
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
      symbolSize: [6, 20],
      lineStyle: %{color: "#666", width: 20, opacity: 0.2}
    }
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
      buttons = Builders.range_buttons()
      active = 1
      now_ms = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
      {x_min, x_max} = Builders.compute_range(Enum.at(buttons, active), now_ms)

      base
      |> Map.put(:xAxis, %{type: "time", min: x_min, max: x_max})
      |> Map.put(:_rangeButtons, buttons)
      |> Map.put(:_activeButton, active)
      |> Map.put(:_enumMembers, int_to_info)
    end
  end

  @impl true
  def build_series(name, ts, vals, datainfo) do
    members = datainfo["members"] || %{}
    [enum_series(name, ts, vals, members)]
  end

  @impl true
  def build_option(series, datainfo, _unit, mode, opts \\ []) do
    members = datainfo["members"] || %{}
    y_categories = Keyword.get(opts, :y_categories)
    enum_timeseries_option(series, members, hd(Enum.map(series, & &1.name)), mode, y_categories)
  end

  @impl true
  def series_updates(option, datapoints, series_name) do
    idx = Enum.find_index(option.series, fn s -> Map.get(s, :name) == series_name end) || 0

    int_to_info = Map.get(option, :_enumMembers, %{})

    y_val =
      case Map.get(option, :_enumSeriesY) do
        nil -> 0
        series_y -> Map.get(series_y, series_name, 0)
      end

    data =
      Enum.map(datapoints, fn {v, ts} ->
        %{name: name, color: color} =
          Map.get(int_to_info, to_string(v), %{name: to_string(v), color: "#888888"})

        %{value: [ts, y_val], name: "#{name} (#{v})", itemStyle: %{color: color}}
      end)

    [%{seriesIndex: idx, data: data}]
  end
end
