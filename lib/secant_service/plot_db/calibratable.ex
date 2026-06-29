defmodule SecantService.PlotDB.Calibratable do
  @behaviour SecantService.PlotDB.PlotSpec

  import SecantService.PlotDB.Builders

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
        scalar_line_series("value", v_ts, v_val),
        scalar_line_series("target", t_ts, t_val),
        scalar_line_series("_value_uncalibrated", vu_ts, vu_val),
        scalar_line_series("_target_calibrated", tc_ts, tc_val)
      ]

      legend_selected = %{
        "_value_uncalibrated" => false,
        "_target_calibrated" => false
      }

      option = timeseries_option(series, unit, mode, legend_selected)
      {:ok, %{plottable: true, plot_available: length(v_val) > 1, option: option}}
    else
      :not_plottable
    end
  end
end
