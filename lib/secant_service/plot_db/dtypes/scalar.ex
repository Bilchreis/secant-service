defmodule SecantService.PlotDB.DTypes.Scalar do
  @behaviour SecantService.PlotDB.DTypePlot

  alias SecantService.PlotDB.Builders

  @markersize 5

  @impl true
  def supported_type?(%{"type" => t}) when t in ["double", "int", "scaled"], do: true
  def supported_type?(_), do: false

  @doc """
  A line of `[ts, value]` points. With `held: true` each reading holds until
  the next one (a setpoint, only recorded when it changes); with
  `setpoint: true` it is also drawn as a module's target (see
  `target_style/2`).
  """
  def scalar_line_series(name, ts_list, val_list, opts \\ []) do
    %{
      name: name,
      type: "line",
      data: Enum.zip_with(ts_list, val_list, &[&1, &2]),
      # a plain line; the marker only shows on the hovered reading
      symbol: "circle",
      symbolSize: @markersize,
      showSymbol: false,
      large: true,
      largeThreshold: 2000,
      # thin out long recordings to what the chart can show
      sampling: "lttb"
    }
    |> held_style(Keyword.get(opts, :held, false) or Keyword.get(opts, :setpoint, false))
    |> target_style(Keyword.get(opts, :setpoint, false))
  end

  # A step line; the hook holds `_held` series' last reading to the end of
  # the chart (to now on a live one).
  defp held_style(series, true), do: Map.merge(series, %{step: "end", _held: true})
  defp held_style(series, false), do: series

  # The target looks like on the dashboard cards: a dashed held line, no
  # markers. The hook gives `_target` series the page's muted colour.
  defp target_style(series, true) do
    Map.merge(series, %{
      showSymbol: false,
      lineStyle: %{width: 2, type: [6, 4]},
      _target: true
    })
  end

  defp target_style(series, false), do: series

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
      Builders.history_zoom(base)
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
  # an unknown series gets nothing: its readings must not land on series 0
  def series_updates(option, datapoints, series_name) do
    case Enum.find_index(option.series, fn s -> Map.get(s, :name) == series_name end) do
      nil ->
        []

      idx ->
        {vals, tss} = Enum.unzip(datapoints)
        [%{seriesIndex: idx, data: Enum.zip_with(tss, vals, &[&1, &2])}]
    end
  end
end
