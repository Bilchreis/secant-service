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

  Number-line plots and numeric array plots (not setpoints) also carry the
  gaps of their session (`_gaps` on the option, see
  `SecantService.PlotDB.Gaps`), where the chart breaks its lines and ends
  its heatmap rows.
  """

  alias SecantService.PlotDB.Bands
  alias SecantService.PlotDB.Builders
  alias SecantService.PlotDB.DTypePlot
  alias SecantService.PlotDB.Gaps
  alias SecantService.PlotDB.DTypes.ArrayHeatmap
  alias SecantService.PlotDB.DTypes.ArrayLatest
  alias SecantService.PlotDB.DTypes.Enum, as: EnumDType
  alias SecantService.PlotDB.DTypes.Scalar
  alias SecantService.PlotDB.DTypes.Struct, as: StructDType
  alias SecantService.PlotDB.Trace

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
      |> array_gaps(value, mode)
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
    |> Gaps.put(lines, gap_window(mode))
  end

  @doc """
  A custom lines plot (`SecantService.PlotDB.LinesPlot`) of resolved trace
  entries (`SecantService.PlotDB.Traces.resolve/2`): one window per distinct
  parameter, each trace's numbers extracted from it, drawn as number lines on
  one or two y-axes, with recording gaps and, in the data browser, bands on
  whole number parameters.

  Besides `option` the plot carries `lines` (by series name, as plots do),
  `resolved` (one line per distinct parameter, `%{param:, series:,
  setpoint?:, hidden?:}`, which the window handlers fetch and gaps and bands
  read) and `traces` (parameter name → its trace entries, which live
  readings fan out to, see `SecantService.PlotDB.trace_updates/3`).
  """
  def build_lines(entries, %{axes: axes}, mode) do
    fetch_lines =
      entries
      |> Enum.group_by(& &1.param.name)
      |> Enum.map(fn {_name, [first | _] = group} ->
        %{
          param: first.param,
          series: first.param.name,
          setpoint?: Enum.any?(group, & &1.setpoint?),
          hidden?: false
        }
      end)

    fetched = Enum.map(fetch_lines, &{&1, fetch(&1, mode)})
    windows = Map.new(fetched, fn {line, window} -> {line.param.name, window} end)

    series =
      for entry <- entries do
        {vals, ts, _res} = Map.fetch!(windows, entry.param.name)
        {ts, vals} = extract_points(ts, vals, entry)

        entry.series
        |> Scalar.scalar_line_series(ts, vals,
          held: entry.setpoint?,
          setpoint: entry.series == "target"
        )
        |> put_label(entry.label)
        |> put_axis(entry.axis)
      end

    legend_selected = for e <- entries, e.hidden?, into: %{}, do: {e.series, false}

    series
    |> Scalar.timeseries_option(axis_unit(entries, axes, 0), mode, legend_selected)
    |> put_second_axis(entries, axes)
    |> custom_plot(entries, fetch_lines, fetched)
    |> Bands.put(fetched, mode)
    |> Gaps.put(fetch_lines, gap_window(mode))
  end

  # a reading without a number where the trace reads gives no point (not a
  # break): a transient error reading doesn't cut the line
  defp extract_points(ts, vals, entry) do
    ts
    |> Enum.zip(vals)
    |> Enum.flat_map(fn {t, v} ->
      case Trace.extract(v, entry.path, entry.index) do
        nil -> []
        x -> [{t, x}]
      end
    end)
    |> Enum.unzip()
  end

  defp put_label(series, nil), do: series
  defp put_label(series, label), do: Map.put(series, :_label, label)

  defp put_axis(series, 1), do: Map.put(series, :yAxisIndex, 1)
  defp put_axis(series, _axis), do: series

  # an axis's label: the plot's name and unit for it, else the unit of its
  # first trace
  defp axis_unit(entries, axes, index) do
    spec = Enum.at(axes || [], index) || %{}
    name = spec[:name]
    unit = spec[:unit] || Enum.find_value(entries, &(&1.axis == index && &1.unit))

    case {name, unit} do
      {nil, unit} -> unit
      {name, nil} -> name
      {name, unit} -> "#{name} (#{unit})"
    end
  end

  defp put_second_axis(option, entries, axes) do
    if Enum.any?(entries, &(&1.axis == 1)) do
      right = %{
        type: "value",
        name: axis_unit(entries, axes, 1) || "",
        nameLocation: "end",
        nameGap: 12,
        nameTextStyle: %{align: "right"},
        position: "right",
        scale: true,
        splitLine: %{show: false}
      }

      # the right axis's name sits in the top right corner, where the zoom
      # tools are: the plot starts lower, so both axis names clear them
      option
      |> Map.update!(:yAxis, &[&1, right])
      |> Map.update!(:grid, &(&1 |> Map.put(:right, 64) |> Map.put(:top, 64)))
    else
      option
    end
  end

  defp custom_plot(option, entries, fetch_lines, fetched) do
    %{
      plottable: true,
      option: option,
      lines: Map.new(entries, &{&1.series, %{series: &1.series, dtype: Scalar}}),
      resolved: fetch_lines,
      traces: Enum.group_by(entries, & &1.param.name)
    }
    |> Builders.put_resolution(Enum.map(fetched, fn {_line, {_v, _t, res}} -> res end))
  end

  # a numeric array gets its session's gaps, unless it is a setpoint (held
  # from before the window, see `fetch/2`)
  defp array_gaps(plot, %{setpoint?: true}, _mode), do: plot
  defp array_gaps(plot, value, mode), do: Gaps.put(plot, [value], gap_window(mode))

  # what the first load covers, for its gaps (`SecantService.PlotDB.Gaps`):
  # a historical plot all of its session, a live one its range
  defp gap_window(:historical), do: {:historical, nil, nil}

  defp gap_window(mode) do
    {from_ms, _to_ms, _buttons, _active} = Builders.default_live_range_ms()
    {mode, from_ms, nil}
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
