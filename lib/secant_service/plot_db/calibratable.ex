defmodule SecantService.PlotDB.Calibratable do
  @behaviour SecantService.PlotDB.PlotSpec

  import SecantService.PlotDB.Builders

  alias SecantService.PlotDB.DTypes.Scalar

  @scalar_types ["double", "int", "scaled"]

  @impl true
  def param_names, do: ["value", "target", "_value_uncalibrated", "_target_calibrated"]

  @impl true
  def plot(module, mode) do
    value_param = find_param(module, "value")

    if value_param && value_param.datainfo["type"] in @scalar_types do
      {v_val, v_ts} = fetch_param_data(value_param)
      {t_val, t_ts} = fetch_param_data(find_param(module, "target"))
      {vu_val, vu_ts} = fetch_param_data(find_param(module, "_value_uncalibrated"))
      {tc_val, tc_ts} = fetch_param_data(find_param(module, "_target_calibrated"))

      unit = get_in(value_param.datainfo, ["unit"])

      series = [
        Scalar.scalar_line_series("value", v_ts, v_val),
        Scalar.scalar_line_series("target", t_ts, t_val),
        Scalar.scalar_line_series("_value_uncalibrated", vu_ts, vu_val),
        Scalar.scalar_line_series("_target_calibrated", tc_ts, tc_val)
      ]

      legend_selected = %{
        "_value_uncalibrated" => false,
        "_target_calibrated" => false
      }

      option = Scalar.timeseries_option(series, unit, mode, legend_selected)

      param_dtype_modules =
        Map.new(param_names(), fn name -> {name, Scalar} end)

      {:ok,
       %{
         plottable: true,
         plot_available: length(v_val) > 1,
         option: option,
         _plot_spec_module: __MODULE__,
         _param_dtype_modules: param_dtype_modules
       }}
    else
      :not_plottable
    end
  end

  @impl true
  def trace_updates(%{_param_dtype_modules: mods, option: opt} = _plot_map, datapoints, param_name) do
    dtype_mod = Map.get(mods, param_name, Scalar)
    series_upds = dtype_mod.series_updates(opt, datapoints, param_name)
    %{seriesUpdates: series_upds}
  end
end
