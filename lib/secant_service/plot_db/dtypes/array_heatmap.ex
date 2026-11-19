defmodule SecantService.PlotDB.DTypes.ArrayHeatmap do
  @behaviour SecantService.PlotDB.DTypePlot

  alias SecantService.PlotDB.Builders

  @heatmap_colors [
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

  @plottable_member_types ["double", "int", "scaled"]

  @impl true
  def supported_type?(%{"type" => "array", "members" => %{"type" => mt}})
      when mt in @plottable_member_types,
      do: true

  def supported_type?(_), do: false

  @doc """
  One series for a 1-D numeric array over time: points `[ts, index, value]`.

  The browser (`_arrayHeat` in app.js) paints it as a time × index heatmap in
  which each reading holds until the next one, or as one line per array
  element.
  """
  def heatmap_series(ts_list, val_list) do
    data =
      Enum.flat_map(Enum.zip(ts_list, val_list), fn {ts, arr} ->
        arr |> Enum.with_index() |> Enum.map(fn {v, i} -> [ts, i, v] end)
      end)

    %{
      type: "custom",
      _arrayHeat: true,
      data: data,
      encode: %{x: 0, y: 1},
      # painted in one pass; chunked rendering would colour only part of it
      progressive: 0
    }
  end

  @doc "Unit of an array's values: SECoP puts it on the members, not the array."
  def unit(datainfo) do
    datainfo["unit"] || get_in(datainfo, ["members", "unit"])
  end

  @doc "Y axis for an array of `array_len` elements: one row per index."
  def index_axis(array_len) do
    %{
      type: "value",
      min: -0.5,
      max: max(array_len, 1) - 0.5,
      minInterval: 1,
      splitLine: %{show: false},
      name: "index",
      nameLocation: "middle",
      nameGap: 40,
      nameRotate: 90
    }
  end

  defp time_axis,
    do: %{type: "time", name: "time", nameLocation: "middle", nameGap: 26}

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

  @doc """
  Option for a 1-D array plot. `opts[:name]` is the parameter name, used for
  the value axis label of the lines view.
  """
  def heatmap_option(series, array_len, unit, mode, opts \\ []) do
    base = %{
      animation: false,
      backgroundColor: "transparent",
      grid: %{top: 12, bottom: 44, left: 64, right: 108},
      xAxis: time_axis(),
      yAxis: index_axis(array_len),
      visualMap: %{
        calculable: true,
        orient: "vertical",
        right: 0,
        top: "middle",
        itemHeight: 160,
        dimension: 2,
        # unit above the colour scale
        text: [unit || "", ""],
        textGap: 14,
        inRange: %{color: @heatmap_colors}
      },
      series: series,
      _arrayLen: array_len,
      _arrayUnit: unit,
      _arrayName: Keyword.get(opts, :name)
    }

    if mode == :historical do
      base
    else
      {x_min, x_max, buttons, active} = Builders.default_live_range_ms()

      base
      |> Map.put(:xAxis, Map.merge(time_axis(), %{min: x_min, max: x_max}))
      |> Map.put(:_rangeButtons, buttons)
      |> Map.put(:_activeButton, active)
    end
  end

  @impl true
  def build_series(_name, ts, vals, _datainfo) do
    [heatmap_series(ts, vals)]
  end

  @impl true
  def build_option(series, _datainfo, unit, mode, opts \\ []) do
    array_len = Keyword.get(opts, :array_len, 0)
    heatmap_option(series, array_len, unit, mode, opts)
  end

  @impl true
  def series_updates(_option, datapoints, _series_name) do
    data =
      Enum.flat_map(datapoints, fn {arr, ts} ->
        arr |> Enum.with_index() |> Enum.map(fn {v, i} -> [ts, i, v] end)
      end)

    [%{seriesIndex: 0, data: data}]
  end

  # longest reading in the batch: lengths can differ between readings
  def array_len_from_datapoints(datapoints),
    do: datapoints |> Enum.map(&elem(&1, 0)) |> max_len()

  @doc """
  Longest array among the loaded readings (lengths can change, e.g. a
  spectrometer that reports 3 points until its first acquisition).
  """
  def max_len(values) do
    Enum.reduce(values, 0, fn
      v, acc when is_list(v) -> max(acc, length(v))
      _, acc -> acc
    end)
  end
end
