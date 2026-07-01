defmodule SecantService.PlotDB.DTypes.ArrayHeatmap do
  @behaviour SecantService.PlotDB.DTypePlot

  alias SecantService.PlotDB.Builders

  @heatmap_colors [
    "#313695", "#4575b4", "#74add1", "#abd9e9", "#e0f3f8",
    "#ffffbf", "#fee090", "#fdae61", "#f46d43", "#d73027", "#a50026"
  ]

  @plottable_member_types ["double", "int", "scaled"]

  @impl true
  def supported_type?(%{"type" => "array", "members" => %{"type" => mt}})
      when mt in @plottable_member_types,
      do: true

  def supported_type?(_), do: false

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

  def heatmap_visual_map(series_index, top, height) do
    %{
      calculable: true,
      orient: "vertical",
      right: 0,
      top: top,
      height: height,
      seriesIndex: series_index,
      dimension: 2,
      inRange: %{color: @heatmap_colors}
    }
  end

  def heatmap_option(series, array_len, unit, mode) do
    _ = unit
    y_max = max(array_len - 1, 0)

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
        inRange: %{color: @heatmap_colors}
      },
      series: series
    }

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
      |> Map.put(:_arrayLen, array_len)
    end
  end

  @impl true
  def build_series(_name, ts, vals, _datainfo) do
    [heatmap_series(ts, vals)]
  end

  @impl true
  def build_option(series, _datainfo, unit, mode, opts \\ []) do
    array_len = Keyword.get(opts, :array_len, 0)
    heatmap_option(series, array_len, unit, mode)
  end

  @impl true
  def series_updates(_option, datapoints, _series_name) do
    data =
      Enum.flat_map(datapoints, fn {arr, ts} ->
        arr |> Enum.with_index() |> Enum.map(fn {v, i} -> [ts, i, v] end)
      end)

    [%{seriesIndex: 0, data: data}]
  end

  def array_len_from_datapoints([{arr, _} | _]), do: length(arr)
  def array_len_from_datapoints([]), do: 0
end
