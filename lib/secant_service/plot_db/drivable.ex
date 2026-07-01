defmodule SecantService.PlotDB.Drivable do
  @behaviour SecantService.PlotDB.PlotSpec

  import SecantService.PlotDB.Builders

  alias SecantService.PlotDB.DTypePlot
  alias SecantService.PlotDB.DTypes.ArrayHeatmap
  alias SecantService.PlotDB.DTypes.Enum, as: EnumDType
  alias SecantService.PlotDB.DTypes.Struct, as: StructDType

  @max_array_len 100

  @impl true
  def param_names, do: ["value", "target"]

  @impl true
  def plot(module, mode) do
    value_param = find_param(module, "value")

    if value_param do
      {v_val, v_ts} = fetch_param_data(value_param)
      unit = get_in(value_param.datainfo, ["unit"])
      dtype_mod = DTypePlot.for_datainfo(value_param.datainfo)

      case dtype_mod do
        nil ->
          :not_plottable

        ArrayHeatmap ->
          array_len = v_val |> List.first([]) |> length()

          if array_len > @max_array_len do
            :not_plottable
          else
            option = ArrayHeatmap.heatmap_option([ArrayHeatmap.heatmap_series(v_ts, v_val)], array_len, unit, mode)

            {:ok,
             %{
               plottable: true,
               plot_available: length(v_val) > 1,
               plot_type: :array_heatmap,
               option: option,
               _plot_spec_module: __MODULE__,
               _param_dtype_modules: %{"value" => dtype_mod}
             }}
          end

        StructDType ->
          target_param = find_param(module, "target")
          {t_val, t_ts} = fetch_param_data(target_param)
          target_opt = if length(t_val) > 0, do: [target: {t_ts, t_val}], else: []

          option = StructDType.build_struct_option("value", v_ts, v_val, value_param.datainfo, mode, target_opt)

          param_mods =
            if length(t_val) > 0,
              do: %{"value" => StructDType, "target" => StructDType},
              else: %{"value" => StructDType}

          {:ok,
           %{
             plottable: true,
             plot_available: length(v_val) > 1,
             option: option,
             _plot_spec_module: __MODULE__,
             _param_dtype_modules: param_mods
           }}

        _enum_or_scalar ->
          target_param = find_param(module, "target")
          {t_val, t_ts} = fetch_param_data(target_param)

          {v_series, t_series, extra_opts} =
            if value_param.datainfo["type"] == "enum" do
              members = value_param.datainfo["members"] || %{}
              v_s = [EnumDType.enum_series("value", v_ts, v_val, members, "value")]
              t_s = [EnumDType.enum_series("target", t_ts, t_val, members, "target")]
              {v_s, t_s, [y_categories: ["target", "value"]]}
            else
              v_s = dtype_mod.build_series("value", v_ts, v_val, value_param.datainfo)
              t_s = dtype_mod.build_series("target", t_ts, t_val, value_param.datainfo)
              {v_s, t_s, []}
            end

          option =
            dtype_mod.build_option(v_series ++ t_series, value_param.datainfo, unit, mode, extra_opts)

          {:ok,
           %{
             plottable: true,
             plot_available: length(v_val) > 1,
             option: option,
             _plot_spec_module: __MODULE__,
             _param_dtype_modules: %{"value" => dtype_mod, "target" => dtype_mod}
           }}
      end
    else
      :not_plottable
    end
  end

  @impl true
  def trace_updates(%{_param_dtype_modules: mods, option: opt} = _plot_map, datapoints, param_name) do
    case Map.get(mods, param_name) do
      nil ->
        %{seriesUpdates: []}

      ArrayHeatmap = dtype_mod ->
        series_upds = dtype_mod.series_updates(opt, datapoints, param_name)
        %{seriesUpdates: series_upds, arrayLen: ArrayHeatmap.array_len_from_datapoints(datapoints)}

      dtype_mod ->
        %{seriesUpdates: dtype_mod.series_updates(opt, datapoints, param_name)}
    end
  end
end
