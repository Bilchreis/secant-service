defmodule SecantService.PlotDB.DTypes.Struct do
  @behaviour SecantService.PlotDB.DTypePlot

  alias SecantService.PlotDB.DTypePlot
  alias SecantService.PlotDB.Builders
  alias SecantService.PlotDB.DTypes.ArrayHeatmap
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
                {:ok, val} -> val
                :error -> Enum.find_value(struct_val, fn {k, fv} -> if to_string(k) == field, do: fv end)
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
        base_idx = Map.get(field_series_indices, field, 0)
        Enum.map(updates, fn u -> %{u | seriesIndex: base_idx + Map.get(u, :seriesIndex, 0)} end)
      else
        updates
      end
    end)
  end

  # Standard ECharts palette — used to assign explicit colors to scalar series so
  # that heatmap series (which use visualMap) don't steal palette slots.
  @echarts_palette ["#5470c6", "#91cc75", "#fac858", "#ee6666", "#73c0de", "#3ba272", "#fc8452", "#9a60b4", "#ea7ccc"]

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

    top_offset = 2.0
    x_axis_reserve = 1.0
    n_f = n * 1.0
    gap = min(5.0, max(0.5, (97.0 - x_axis_reserve) / n_f / 4.0))
    row_height = max((97.0 - x_axis_reserve - (n - 1) * gap) / n_f, 2.0)
    row_h = row_height + gap

    titles =
      fields
      |> Enum.with_index()
      |> Enum.map(fn {{field, sub_datainfo}, idx} ->
        top_pct = top_offset + idx * row_h
        title_top = max(0.6, top_pct - gap * 0.7)
        unit = Map.get(sub_datainfo, "unit")
        text = if unit && unit != "", do: "#{field} (#{unit})", else: field
        %{
          text: text,
          top: "#{Float.round(title_top, 1)}%",
          left: 85,
          backgroundColor: "rgba(0,0,0,0.45)",
          padding: [2, 5],
          textStyle: %{fontSize: 11, color: "#e0e0e0"}
        }
      end)

    # Accumulator fields:
    #   gs/xs/ys/ss/fdps/esy/em  — standard ECharts option accumulators
    #   sc                        — total series count so far (for seriesIndex)
    #   vms                       — visualMap entries for heatmap sub-fields
    #   ln                        — legend names for scalar sub-fields only
    #   fsi                       — {field => series_start_index} for ArrayHeatmap seriesIndex fix
    #   sci                       — scalar color index (independent of heatmap series count)
    #   sr                        — scalar region {min_top_pct, max_bottom_pct} for legend position
    init = {[], [], [], [], [], %{}, %{}, 0, [], [], %{}, 0, {100.0, 0.0}}

    {grids, x_axes, y_axes, all_series, field_dtype_pairs, enum_series_y, enum_members,
     _sc, visual_maps, legend_names, field_series_indices, _sci, scalar_region} =
      fields
      |> Enum.with_index()
      |> Enum.reduce(init, fn {{field, sub_datainfo}, idx}, {gs, xs, ys, ss, fdps, esy, em, sc, vms, ln, fsi, sci, sr} ->
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
              t_field_vals = Enum.map(t_vals, fn v -> if is_map(v), do: Map.get(v, field), else: nil end)
              v_s = EnumDType.enum_series(val_series_name, ts, field_vals, members, "value")
              t_s = EnumDType.enum_series("target.#{field}", t_ts, t_field_vals, members, "target")
              y_opts = %{type: "category", data: ["target", "value"], axisTick: %{show: false}, axisLine: %{show: false}}
              {[v_s, t_s], y_opts, %{val_series_name => "value", "target.#{field}" => "target"}, EnumDType.enum_int_to_info(members)}

            _ ->
              raw = dtype_mod.build_series(val_series_name, ts, field_vals, sub_datainfo)
              extra =
                case target do
                  {t_ts, t_vals} ->
                    t_field_vals = Enum.map(t_vals, fn v -> if is_map(v), do: Map.get(v, field), else: nil end)
                    dtype_mod.build_series("target.#{field}", t_ts, t_field_vals, sub_datainfo)
                  nil -> []
                end
              y_opts =
                if dtype_mod == ArrayHeatmap do
                  array_len = sub_datainfo["minlen"] || sub_datainfo["maxlen"] || 0
                  %{type: "value", min: 0, max: max(array_len - 1, 0), minInterval: 1}
                else
                  %{type: "value"}
                end
              {raw ++ extra, y_opts, %{}, %{}}
          end

        indexed_series = Enum.map(field_series, &Map.merge(&1, %{xAxisIndex: idx, yAxisIndex: idx}))
        series_count = length(indexed_series)

        x_axis =
          if idx == last_idx do
            %{gridIndex: idx, type: "time"}
          else
            %{gridIndex: idx, type: "time", axisLabel: %{show: false}, axisTick: %{show: false}}
          end

        y_axis =
          if !is_enum && dtype_mod != ArrayHeatmap && unit && unit != "" do
            Map.merge(y_type_opts, %{gridIndex: idx, name: unit, nameLocation: "middle", nameRotate: 90, nameGap: 35})
          else
            Map.merge(y_type_opts, %{gridIndex: idx})
          end

        new_vms =
          if dtype_mod == ArrayHeatmap do
            vm_indices = if series_count == 1, do: sc, else: Enum.to_list(sc..(sc + series_count - 1))
            [ArrayHeatmap.heatmap_visual_map(vm_indices, top, "#{Float.round(row_height, 1)}%") | vms]
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
                  Map.put(s, :itemStyle, %{color: Enum.at(@echarts_palette, rem(ci, length(@echarts_palette)))})
                end)
              new_names = ln ++ Enum.map(indexed_series, & &1.name)
              {sr_top, sr_bottom} = sr
              new_sr = {min(sr_top, top_pct), max(sr_bottom, top_pct + row_height)}
              {colored, new_names, sci + series_count, new_sr}
          end

        grid_height = if(idx == last_idx, do: row_height + x_axis_reserve, else: row_height)
        {
          [%{show: true, left: 60, right: 90, top: top, height: "#{Float.round(grid_height, 1)}%", containLabel: true, backgroundColor: "rgba(255,255,255,0.04)"} | gs],
          [x_axis | xs],
          [y_axis | ys],
          ss ++ indexed_series_final,
          [{field, dtype_mod} | fdps],
          Map.merge(esy, new_esy),
          Map.merge(em, new_em),
          sc + series_count,
          new_vms,
          new_ln,
          Map.put(fsi, field, sc),
          new_sci,
          new_sr
        }
      end)

    legend =
      case {legend_names, scalar_region} do
        {[], _} ->
          nil
        {names, {top_pct, bottom_pct}} when top_pct <= bottom_pct ->
          center = Float.round((top_pct + bottom_pct) / 2.0, 1)
          %{data: names, orient: "vertical", right: 0, top: "#{center}%", itemGap: 8}
        {names, _} ->
          %{data: names, orient: "vertical", right: 0, top: "center", itemGap: 8}
      end

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

    option = if legend, do: Map.put(option, :legend, legend), else: option
    option = if visual_maps != [], do: Map.put(option, :visualMap, Enum.reverse(visual_maps)), else: option
    option = if map_size(enum_series_y) > 0, do: Map.put(option, :_enumSeriesY, enum_series_y), else: option
    option = if map_size(enum_members) > 0, do: Map.put(option, :_enumMembers, enum_members), else: option

    if mode == :live do
      buttons = Builders.range_buttons()
      active = 1
      now_ms = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
      {x_min, x_max} = Builders.compute_range(Enum.at(buttons, active), now_ms)
      live_x_axes = Enum.map(option.xAxis, &Map.merge(&1, %{min: x_min, max: x_max}))

      option
      |> Map.put(:xAxis, live_x_axes)
      |> Map.put(:_rangeButtons, buttons)
      |> Map.put(:_activeButton, active)
    else
      option
    end
  end

  # ---------------------------------------------------------------------------

  defp plottable_fields(datainfo) do
    members = datainfo["members"] || %{}

    members
    |> Enum.filter(fn {_name, sub} -> DTypePlot.for_datainfo(sub) != nil end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end
end
