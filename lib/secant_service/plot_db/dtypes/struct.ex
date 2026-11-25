defmodule SecantService.PlotDB.DTypes.Struct do
  @behaviour SecantService.PlotDB.DTypePlot

  alias SecantService.PlotDB.DTypePlot
  alias SecantService.PlotDB.Builders
  alias SecantService.PlotDB.DTypes.ArrayHeatmap
  alias SecantService.PlotDB.History.Channels
  alias SecantService.PlotDB.DTypes.Enum, as: EnumDType

  @impl true
  def supported_type?(%{"type" => "struct", "members" => members}) when is_map(members) do
    Enum.any?(members, fn {_name, sub} -> DTypePlot.for_datainfo(sub) != nil end)
  end

  def supported_type?(_), do: false

  @impl true
  def build_series(name, ts, vals, datainfo) do
    plottable_fields(datainfo)
    |> Enum.flat_map(fn {field, sub_datainfo} ->
      dtype_mod = DTypePlot.for_datainfo(sub_datainfo)
      field_vals = Enum.map(vals, fn v -> if is_map(v), do: Map.get(v, field), else: nil end)
      dtype_mod.build_series("#{name}.#{field}", ts, field_vals, sub_datainfo)
    end)
  end

  # build_option is not meaningful here since struct needs its own multi-grid builder.
  # Call build_struct_option/5 directly instead.
  @impl true
  def build_option(_series, _datainfo, _unit, _mode, _opts \\ []) do
    raise "Struct plots must be built with build_struct_option/5"
  end

  @impl true
  def series_updates(option, datapoints, series_name) do
    field_dtype_map = Map.get(option, :_structFields, %{})
    field_series_indices = Map.get(option, :_fieldSeriesIndices, %{})
    fields = Map.keys(field_dtype_map)

    # Single pass over datapoints: build all per-field lists simultaneously
    # instead of iterating datapoints once per field.
    field_datapoints_map =
      Enum.reduce(datapoints, Map.new(fields, fn f -> {f, []} end), fn {struct_val, ts}, acc ->
        Enum.reduce(fields, acc, fn field, acc ->
          v =
            if is_map(struct_val) do
              case Map.fetch(struct_val, field) do
                {:ok, val} ->
                  val

                :error ->
                  Enum.find_value(struct_val, fn {k, fv} -> if to_string(k) == field, do: fv end)
              end
            end

          Map.update!(acc, field, &[{v, ts} | &1])
        end)
      end)

    Enum.flat_map(field_dtype_map, fn {field, dtype_mod} ->
      field_series_name = "#{series_name}.#{field}"
      field_datapoints = field_datapoints_map |> Map.get(field, []) |> Enum.reverse()
      updates = dtype_mod.series_updates(option, field_datapoints, field_series_name)

      if dtype_mod == ArrayHeatmap do
        # by series name: a drivable's value and target each have a heatmap
        base_idx = Map.get(field_series_indices, field_series_name, 0)
        Enum.map(updates, fn u -> %{u | seriesIndex: base_idx + Map.get(u, :seriesIndex, 0)} end)
      else
        updates
      end
    end)
  end

  # Standard ECharts palette — used to assign explicit colors to scalar series so
  # that heatmap series (which use visualMap) don't steal palette slots.
  @echarts_palette [
    "#5470c6",
    "#91cc75",
    "#fac858",
    "#ee6666",
    "#73c0de",
    "#3ba272",
    "#fc8452",
    "#9a60b4",
    "#ea7ccc"
  ]

  @doc """
  Re-fit a struct plot's sub-grids, titles and colour scales to the real chart
  height in pixels, so title bands, gaps and the time axis keep their size on
  short (dashboard) and tall (history page) charts alike.
  """
  def fit_height(%{option: %{_structFields: fields, grid: grids} = opt} = plot, height)
      when is_map(fields) and is_list(grids) and is_number(height) do
    n = max(length(grids), 1)
    l = layout(n, height, Map.has_key?(opt, :legend))
    pct = fn v -> "#{Float.round(v, 2)}%" end
    row_top = fn i -> l.top + i * (l.row + l.gap) end

    grid =
      grids
      |> Enum.with_index()
      |> Enum.map(fn {g, i} ->
        # labels sit outside the grid (shared gutter), in the reserved band below
        h = l.row
        %{g | top: pct.(row_top.(i)), height: pct.(h)}
      end)

    title =
      opt.title
      |> Enum.with_index()
      |> Enum.map(fn {t, i} -> %{t | top: pct.(max(0.0, row_top.(i) - l.band))} end)

    opt = %{opt | grid: grid, title: title}

    opt =
      case opt do
        %{visualMap: vms} when is_list(vms) ->
          vms =
            Enum.map(vms, fn vm ->
              i = Map.get(vm, :_row, 0)
              # bar plus its end handles fill the sub-grid
              Map.merge(vm, %{top: pct.(row_top.(i)), itemHeight: max(round(l.row_px - 12), 16)})
            end)

          %{opt | visualMap: vms}

        _ ->
          opt
      end

    %{plot | option: opt}
  end

  def fit_height(plot, _height), do: plot

  # Sub-grid layout in percent of the chart height, from fixed pixel sizes:
  # a title band above every grid, a gap between grids, room for the time
  # axis under the last one and, if needed, a legend row at the bottom.
  defp layout(n, height, has_legend) do
    h = height * 1.0
    band = 24
    top = band + 4
    gap = band + 8
    x_reserve = 24
    legend = if has_legend, do: 26, else: 0
    row_px = max((h - top - x_reserve - legend - (n - 1) * gap - 4) / n, 12.0)
    to_pct = fn px -> px / h * 100.0 end

    %{
      band: to_pct.(band),
      top: to_pct.(top),
      gap: to_pct.(gap),
      row: to_pct.(row_px),
      x_reserve: to_pct.(x_reserve),
      row_px: row_px
    }
  end

  @doc """
  Build a complete multi-grid ECharts option for a struct-typed parameter.

  One grid row per plottable field, stacked vertically. The option includes
  `_structFields` — an ordered list of `{field_name, dtype_module}` pairs used
  by `series_updates/3` to decompose live struct updates back to per-field series.
  """
  def build_struct_option(param_name, ts, vals, datainfo, mode, opts \\ []) do
    target = Keyword.get(opts, :target)
    fields = plottable_fields(datainfo)
    n = max(length(fields), 1)
    last_idx = n - 1

    # scalar sub-fields get a legend; it takes its own band under the x axis
    has_legend =
      Enum.any?(fields, fn {_field, di} ->
        di["type"] != "enum" and DTypePlot.for_datainfo(di) != ArrayHeatmap
      end)

    # Built for the usual chart height (HistoryDB.chart_height/2); fit_height/2
    # redoes the positions once the real height is known.
    %{band: title_band, top: top_offset, gap: gap, row: row_height} =
      layout(n, max(n * 80, 240), has_legend)

    row_h = row_height + gap

    titles =
      fields
      |> Enum.with_index()
      |> Enum.map(fn {{field, sub_datainfo}, idx} ->
        top_pct = top_offset + idx * row_h
        title_top = max(0.0, top_pct - title_band)
        unit = Map.get(sub_datainfo, "unit")
        text = if unit && unit != "", do: "#{field} (#{unit})", else: field

        # an array with a setpoint: value and target share each heatmap
        # cell; as lines (`_linesText`), the target is dashed
        {text, lines_text} =
          if target && DTypePlot.for_datainfo(sub_datainfo) == ArrayHeatmap,
            do: {"#{text}  ·  upper half value, lower half target", "#{text}  ·  target dashed"},
            else: {text, nil}

        %{
          text: text,
          _linesText: lines_text,
          top: "#{Float.round(title_top, 1)}%",
          left: 91,
          padding: [2, 5],
          textStyle: %{fontSize: 12, fontWeight: 600}
        }
      end)

    # Accumulator fields:
    #   gs/xs/ys/ss/fdps/esy/em  — standard ECharts option accumulators
    #   sc                        — total series count so far (for seriesIndex)
    #   vms                       — visualMap entries for heatmap sub-fields
    #   ln                        — legend names for scalar sub-fields only
    #   fsi                       — {series name => series index}, to route array updates
    #   sci                       — scalar color index (independent of heatmap series count)
    #   sr                        — scalar region {min_top_pct, max_bottom_pct} for legend position
    init = {[], [], [], [], [], %{}, %{}, 0, [], [], %{}, 0, {100.0, 0.0}}

    {grids, x_axes, y_axes, all_series, field_dtype_pairs, enum_series_y, enum_members, _sc,
     visual_maps, legend_names, field_series_indices, _sci, scalar_region} =
      fields
      |> Enum.with_index()
      |> Enum.reduce(init, fn {{field, sub_datainfo}, idx},
                              {gs, xs, ys, ss, fdps, esy, em, sc, vms, ln, fsi, sci, sr} ->
        dtype_mod = DTypePlot.for_datainfo(sub_datainfo)
        field_vals = Enum.map(vals, fn v -> if is_map(v), do: Map.get(v, field), else: nil end)
        val_series_name = "#{param_name}.#{field}"
        is_enum = sub_datainfo["type"] == "enum"
        top_pct = top_offset + idx * row_h
        top = "#{Float.round(top_pct, 1)}%"
        unit = Map.get(sub_datainfo, "unit")

        {field_series, y_type_opts, new_esy, new_em} =
          case {is_enum, target} do
            {true, {t_ts, t_vals}} ->
              members = sub_datainfo["members"] || %{}

              t_field_vals =
                Enum.map(t_vals, fn v -> if is_map(v), do: Map.get(v, field), else: nil end)

              v_s = EnumDType.enum_series(val_series_name, ts, field_vals, members, "value")

              t_s =
                EnumDType.enum_series("target.#{field}", t_ts, t_field_vals, members, "target")

              y_opts = %{
                type: "category",
                data: ["target", "value"],
                axisTick: %{show: false},
                axisLine: %{show: false}
              }

              {[v_s, t_s], y_opts, %{val_series_name => "value", "target.#{field}" => "target"},
               EnumDType.enum_int_to_info(members)}

            _ ->
              raw = dtype_mod.build_series(val_series_name, ts, field_vals, sub_datainfo)

              extra =
                case target do
                  {t_ts, t_vals} ->
                    t_field_vals =
                      Enum.map(t_vals, fn v -> if is_map(v), do: Map.get(v, field), else: nil end)

                    dtype_mod.build_series("target.#{field}", t_ts, t_field_vals, sub_datainfo)

                  nil ->
                    []
                end

              array_len =
                max(
                  Channels.declared_length(sub_datainfo, max: Channels.max_drawn_length()) || 0,
                  ArrayHeatmap.max_len(field_vals)
                )

              y_opts =
                if dtype_mod == ArrayHeatmap do
                  ArrayHeatmap.index_axis(array_len) |> Map.drop([:name, :nameGap])
                else
                  if is_enum,
                    do: %{type: "value", axisLabel: %{show: false}, splitLine: %{show: false}},
                    else: %{type: "value", splitNumber: 3, axisLabel: %{hideOverlap: true}}
                end

              series =
                if dtype_mod == ArrayHeatmap,
                  do: array_series(raw, extra, val_series_name, "target.#{field}", array_len),
                  else: raw ++ extra

              {series, y_opts, %{}, %{}}
          end

        indexed_series =
          Enum.map(field_series, &Map.merge(&1, %{xAxisIndex: idx, yAxisIndex: idx}))

        series_count = length(indexed_series)

        x_axis =
          if idx == last_idx do
            %{gridIndex: idx, type: "time"}
          else
            %{gridIndex: idx, type: "time", axisLabel: %{show: false}, axisTick: %{show: false}}
          end

        y_axis =
          if !is_enum && dtype_mod != ArrayHeatmap && unit && unit != "" do
            Map.merge(y_type_opts, %{
              gridIndex: idx,
              name: unit,
              nameLocation: "middle",
              nameRotate: 90,
              nameGap: 56
            })
          else
            Map.merge(y_type_opts, %{gridIndex: idx})
          end

        new_vms =
          if dtype_mod == ArrayHeatmap do
            vm_indices =
              if series_count == 1, do: sc, else: Enum.to_list(sc..(sc + series_count - 1))

            [
              ArrayHeatmap.heatmap_visual_map(vm_indices, top, "#{Float.round(row_height, 1)}%")
              |> Map.merge(heat_range(indexed_series))
              |> Map.put(:_row, idx)
              | vms
            ]
          else
            vms
          end

        {indexed_series_final, new_ln, new_sci, new_sr} =
          cond do
            dtype_mod == ArrayHeatmap ->
              {indexed_series, ln, sci, sr}

            is_enum ->
              {indexed_series, ln, sci, sr}

            true ->
              colored =
                indexed_series
                |> Enum.with_index(sci)
                |> Enum.map(fn {s, ci} ->
                  Map.put(s, :itemStyle, %{
                    color: Enum.at(@echarts_palette, rem(ci, length(@echarts_palette)))
                  })
                end)

              new_names = ln ++ Enum.map(indexed_series, & &1.name)
              {sr_top, sr_bottom} = sr
              new_sr = {min(sr_top, top_pct), max(sr_bottom, top_pct + row_height)}
              {colored, new_names, sci + series_count, new_sr}
          end

        grid_height = row_height

        {
          [
            %{
              show: true,
              left: 96,
              right: 90,
              top: top,
              height: "#{Float.round(grid_height, 1)}%",
              containLabel: false,
              borderWidth: 0,
              backgroundColor: "rgba(255,255,255,0.04)"
            }
            | gs
          ],
          [x_axis | xs],
          [y_axis | ys],
          ss ++ indexed_series_final,
          [{field, dtype_mod} | fdps],
          Map.merge(esy, new_esy),
          Map.merge(em, new_em),
          sc + series_count,
          new_vms,
          new_ln,
          indexed_series
          |> Enum.with_index(sc)
          |> Enum.reduce(fsi, fn {s, i}, acc -> Map.put(acc, s[:name], i) end),
          new_sci,
          new_sr
        }
      end)

    legend =
      case {legend_names, scalar_region} do
        {[], _} ->
          nil

        {names, _scalar_region} ->
          # one scrolling row along the bottom, under the x axis
          %{data: names, type: "scroll", orient: "horizontal", bottom: 0, left: 16, right: 16}
      end

    grids =
      if visual_maps == [],
        do: Enum.map(grids, &Map.put(&1, :right, 32)),
        else: grids

    option = %{
      backgroundColor: "transparent",
      animation: false,
      axisPointer: %{link: [%{xAxisIndex: "all"}], label: %{backgroundColor: "#6a7985"}},
      title: titles,
      grid: Enum.reverse(grids),
      xAxis: Enum.reverse(x_axes),
      yAxis: Enum.reverse(y_axes),
      series: all_series,
      _structFields: Map.new(Enum.reverse(field_dtype_pairs)),
      _fieldSeriesIndices: field_series_indices
    }

    # keep the legend clear of a heatmap colour scale (right: 0)
    legend = legend && if(visual_maps != [], do: %{legend | right: 100}, else: legend)
    option = if legend, do: Map.put(option, :legend, legend), else: option

    option =
      if visual_maps != [],
        do: Map.put(option, :visualMap, Enum.reverse(visual_maps)),
        else: option

    option =
      if map_size(enum_series_y) > 0,
        do: Map.put(option, :_enumSeriesY, enum_series_y),
        else: option

    option =
      if map_size(enum_members) > 0,
        do: Map.put(option, :_enumMembers, enum_members),
        else: option

    if mode == :live do
      {x_min, x_max, buttons, active} = Builders.default_live_range_ms()
      live_x_axes = Enum.map(option.xAxis, &Map.merge(&1, %{min: x_min, max: x_max}))

      option
      |> Map.put(:xAxis, live_x_axes)
      |> Map.put(:_rangeButtons, buttons)
      |> Map.put(:_activeButton, active)
    else
      Builders.history_zoom(option, x_axes: length(option.xAxis), keep_outside: true)
    end
  end

  # ---------------------------------------------------------------------------

  # The heatmap series of an array field, named like the other series so
  # updates find them, with their element count for the lines view. With a
  # setpoint, value and target share each cell: value in the upper half,
  # target in the lower one (see `_arrayHeat` in app.js).
  defp array_series(value, [], value_name, _target_name, len),
    do: Enum.map(value, &Map.merge(&1, %{name: value_name, _arrayLen: len}))

  defp array_series(value, target, value_name, target_name, len) do
    Enum.map(value, &Map.merge(&1, %{name: value_name, _arrayLen: len, _heatHalf: "upper"})) ++
      Enum.map(
        target,
        &Map.merge(&1, %{
          name: target_name,
          _arrayLen: len,
          _heatHalf: "lower",
          _targetArray: true
        })
      )
  end

  # colour scale of a heatmap row: the range of its values (ECharts would
  # otherwise assume 0 … 100)
  defp heat_range(series) do
    values = for %{data: data} <- series, [_, _, v] <- data, is_number(v), do: v

    case values do
      [] ->
        %{}

      _ ->
        {lo, hi} = Enum.min_max(values)
        %{min: lo, max: if(hi == lo, do: lo + 1, else: hi)}
    end
  end

  defp plottable_fields(datainfo) do
    members = datainfo["members"] || %{}

    members
    |> Enum.filter(fn {_name, sub} -> DTypePlot.for_datainfo(sub) != nil end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end
end
