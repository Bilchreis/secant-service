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
      largeThreshold: 2000
    }
  end

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
      buttons = Builders.range_buttons()
      active = 1
      now_ms = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
      {x_min, x_max} = Builders.compute_range(Enum.at(buttons, active), now_ms)

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
