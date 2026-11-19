defmodule SecantService.PlotDB.DTypes.Scalar do
  @behaviour SecantService.PlotDB.DTypePlot

  alias SecantService.PlotDB.Builders

  @markersize 5

  @impl true
  def supported_type?(%{"type" => t}) when t in ["double", "int", "scaled"], do: true
  def supported_type?(_), do: false

  def scalar_line_series(name, ts_list, val_list) do
    %{
      name: name,
      type: "line",
      data: Enum.zip_with(ts_list, val_list, &[&1, &2]),
      symbol: "circle",
      symbolSize: @markersize,
      large: true,
      largeThreshold: 2000,
      # thin out long recordings to what the chart can show
      sampling: "lttb"
    }
  end

  def timeseries_option(series, unit, mode, legend_selected \\ %{}) do
    base = %{
      backgroundColor: "transparent",
      # legend on top so it never covers the data in the narrow inspector
      legend: %{type: "scroll", orient: "horizontal", left: 0, right: 64, top: 0},
      # top leaves room for the legend and the unit above the y axis
      grid: %{top: 44, bottom: 40, left: 60, right: 24},
      tooltip: %{trigger: "axis"},
      xAxis: %{type: "time"},
      # scale: don't force 0 into the range, so drift around a setpoint is visible
      yAxis: %{
        type: "value",
        name: unit || "",
        nameLocation: "end",
        nameGap: 12,
        nameTextStyle: %{align: "left"},
        scale: true
      },
      series: series
    }

    base =
      if map_size(legend_selected) > 0 do
        Map.update!(base, :legend, &Map.put(&1, :selected, legend_selected))
      else
        base
      end

    if mode == :historical do
      # mouse-wheel / drag zoom, a box-zoom tool and a reset
      base
      |> Map.put(:dataZoom, [%{type: "inside", xAxisIndex: 0}])
      |> Map.put(:toolbox, %{
        right: 8,
        top: 0,
        feature: %{dataZoom: %{yAxisIndex: "none"}, restore: %{}}
      })
    else
      {x_min, x_max, buttons, active} = Builders.default_live_range_ms()

      base
      |> Map.put(:xAxis, %{type: "time", min: x_min, max: x_max})
      |> Map.put(:_rangeButtons, buttons)
      |> Map.put(:_activeButton, active)
    end
  end

  @impl true
  def build_series(name, ts, vals, _datainfo) do
    [scalar_line_series(name, ts, vals)]
  end

  @impl true
  def build_option(series, _datainfo, unit, mode, opts \\ []) do
    legend_selected = Keyword.get(opts, :legend_selected, %{})
    timeseries_option(series, unit, mode, legend_selected)
  end

  @impl true
  def series_updates(option, datapoints, series_name) do
    idx = Enum.find_index(option.series, fn s -> Map.get(s, :name) == series_name end) || 0
    {vals, tss} = Enum.unzip(datapoints)
    data = Enum.zip_with(tss, vals, &[&1, &2])
    [%{seriesIndex: idx, data: data}]
  end
end
