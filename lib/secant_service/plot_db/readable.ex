defmodule SecantService.PlotDB.Readable do
  @behaviour SecantService.PlotDB.PlotSpec

  import SecantService.PlotDB.Builders

  alias SecantService.PlotDB.DTypePlot
  alias SecantService.PlotDB.DTypes.ArrayHeatmap
  alias SecantService.PlotDB.DTypes.Struct

  @max_array_len 100

  @impl true
  def param_names, do: ["value"]

  @impl true
  def plot(module, mode) do
    value_param = find_param(module, "value")

    if value_param do
      {val, ts} = fetch_param_data(value_param)
      unit = get_in(value_param.datainfo, ["unit"])
      dtype_mod = DTypePlot.for_datainfo(value_param.datainfo)

      case dtype_mod do
        nil ->
          :not_plottable

        ArrayHeatmap ->
          array_len = val |> List.first([]) |> length()

          if array_len > @max_array_len do
            :not_plottable
          else
            option = ArrayHeatmap.heatmap_option([ArrayHeatmap.heatmap_series(ts, val)], array_len, unit, mode)

            {:ok,
             %{
               plottable: true,
               plot_available: length(val) > 1,
               plot_type: :array_heatmap,
               option: option,
               _plot_spec_module: __MODULE__,
               _param_dtype_modules: %{"value" => dtype_mod}
             }}
          end

        Struct ->
          option = Struct.build_struct_option("value", ts, val, value_param.datainfo, mode)

          {:ok,
           %{
             plottable: true,
             plot_available: length(val) > 1,
             option: option,
             _plot_spec_module: __MODULE__,
             _param_dtype_modules: %{"value" => dtype_mod}
           }}

        _enum_or_scalar ->
          series = dtype_mod.build_series("value", ts, val, value_param.datainfo)
          option = dtype_mod.build_option(series, value_param.datainfo, unit, mode, [])

          {:ok,
           %{
             plottable: true,
             plot_available: length(val) > 1,
             option: option,
             _plot_spec_module: __MODULE__,
             _param_dtype_modules: %{"value" => dtype_mod}
           }}
      end
    else
      :not_plottable
    end
  end

  @impl true
  def trace_updates(%{_param_dtype_modules: mods, option: opt} = _plot_map, datapoints, param_name) do
    dtype_mod = Map.get(mods, param_name)
    series_upds = dtype_mod.series_updates(opt, datapoints, param_name)
    result = %{seriesUpdates: series_upds}

    if dtype_mod == ArrayHeatmap do
      Map.put(result, :arrayLen, ArrayHeatmap.array_len_from_datapoints(datapoints))
    else
      result
    end
  end
end
