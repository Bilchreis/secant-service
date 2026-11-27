defmodule SecantService.PlotDB.TimePlot do
  @moduledoc """
  The plot of a parameter or module over time, built from its lines (see
  `SecantService.PlotDB.lines/1`): the value, and for a Drivable or
  Calibratable its setpoint and extra lines.

  The value's type picks the drawing: numbers as lines, enums as state
  bands, short numeric arrays as a time × index heatmap (long ones as their
  latest reading, see `ArrayLatest`), structs as one row per field.

  The plot map carries `lines`, `%{parameter name => %{series:, dtype:}}`,
  so live readings and zoomed windows of a parameter find the series they
  belong to (see `SecantService.PlotDB.trace_updates/3`).
  """

  alias SecantService.PlotDB.Bands
  alias SecantService.PlotDB.Builders
  alias SecantService.PlotDB.DTypePlot
  alias SecantService.PlotDB.DTypes.ArrayHeatmap
  alias SecantService.PlotDB.DTypes.ArrayLatest
  alias SecantService.PlotDB.DTypes.Enum, as: EnumDType
  alias SecantService.PlotDB.DTypes.Scalar
  alias SecantService.PlotDB.DTypes.Struct, as: StructDType

  # longest array the heatmap carries; longer ones are plotted as their
  # latest reading
  @max_array_len 100

  def max_array_len, do: @max_array_len

  @doc "The plot of `lines` (value first), or `:not_plottable`."
  def build([%{param: value} | _] = lines, mode) do
    case DTypePlot.for_datainfo(value.datainfo) do
      nil -> :not_plottable
      dtype -> build(dtype, lines, mode)
    end
  end

  def build([], _mode), do: :not_plottable

  # a heatmap has room for the value only
  defp build(ArrayHeatmap, [value | _], mode) do
    {vals, ts, resolution} = fetch(value, mode)
    array_len = ArrayHeatmap.max_len(vals)

    # a long reading inside the window: plot the latest reading instead
    if array_len > @max_array_len do
      ArrayLatest.plot(value.param, ArrayLatest.fetch_latest(value.param))
    else
      [ArrayHeatmap.heatmap_series(ts, vals)]
      |> ArrayHeatmap.heatmap_option(
        array_len,
        ArrayHeatmap.unit(value.param.datainfo),
        mode,
        name: value.param.name
      )
      |> plot([value], ArrayHeatmap, [resolution])
      |> Map.put(:plot_type, :array_heatmap)
    end
  end

  defp build(StructDType, [value | rest], mode) do
    {vals, ts, resolution} = fetch(value, mode)

    {target_opt, drawn, resolutions} =
      case setpoint(rest) do
        nil ->
          {[], [value], [resolution]}

        target ->
          {t_vals, t_ts, t_res} = fetch(target, mode)
          {[target: {t_ts, t_vals}], [value, target], [resolution, t_res]}
      end

    value.series
    |> StructDType.build_struct_option(ts, vals, value.param.datainfo, mode, target_opt)
    |> plot(drawn, StructDType, resolutions)
  end

  defp build(EnumDType, [value | rest], mode) do
    members = value.param.datainfo["members"] || %{}
    {vals, ts, resolution} = fetch(value, mode)

    case setpoint(rest) do
      nil ->
        [EnumDType.enum_series(value.series, ts, vals, members)]
        |> EnumDType.enum_timeseries_option(members, mode)
        |> plot([value], EnumDType, [resolution])

      target ->
        {t_vals, t_ts, t_res} = fetch(target, mode)

        [
          EnumDType.enum_series(value.series, ts, vals, members, "value"),
          EnumDType.enum_series(target.series, t_ts, t_vals, members, "target")
        ]
        |> EnumDType.enum_timeseries_option(members, mode, ["target", "value"])
        |> plot([value, target], EnumDType, [resolution, t_res])
    end
  end

  defp build(Scalar, [value | _] = lines, mode) do
    fetched = Enum.map(lines, &{&1, fetch(&1, mode)})

    series =
      for {line, {vals, ts, _res}} <- fetched do
        # every setpoint holds its readings (see fetch/2); a module's
        # target is also drawn dashed and muted
        Scalar.scalar_line_series(line.series, ts, vals,
          held: line.setpoint?,
          setpoint: line.series == "target"
        )
      end

    legend_selected = for line <- lines, line.hidden?, into: %{}, do: {line.series, false}

    series
    |> Scalar.timeseries_option(value.param.datainfo["unit"], mode, legend_selected)
    |> plot(lines, Scalar, Enum.map(fetched, fn {_line, {_v, _t, res}} -> res end))
    |> Bands.put(fetched, mode)
  end

  defp plot(option, lines, dtype, resolutions) do
    %{
      plottable: true,
      option: option,
      lines: Map.new(lines, &{&1.param.name, %{series: &1.series, dtype: dtype}})
    }
    |> Builders.put_resolution(resolutions)
  end

  defp setpoint(lines), do: Enum.find(lines, & &1.setpoint?)

  # A setpoint is only recorded when it changes: its readings are held from
  # before the window (see `Builders.fetch_held_param_window/2`).
  defp fetch(%{setpoint?: true, param: param}, mode),
    do: Builders.fetch_held_param_window(param, mode)

  defp fetch(line, mode),
    do: Builders.fetch_param_window(line.param, mode, envelope: Bands.on_load?(line, mode))
end
