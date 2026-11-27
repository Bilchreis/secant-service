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
      vu_param = find_param(module, "_value_uncalibrated")

      {v_val, v_ts, v_res} =
        fetch_param_window(value_param, mode,
          envelope: envelope_on_load?(module, value_param, mode)
        )

      {t_val, t_ts, t_res} = fetch_optional(find_param(module, "target"), mode, :held)

      {vu_val, vu_ts, vu_res} =
        fetch_optional(vu_param, mode, :plain,
          envelope: envelope_on_load?(module, vu_param, mode)
        )

      {tc_val, tc_ts, tc_res} = fetch_optional(find_param(module, "_target_calibrated"), mode)

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
         plot_available: plot_available?(v_val, value_param, mode),
         option: option,
         _plot_spec_module: __MODULE__,
         _param_dtype_modules: param_dtype_modules
       }}
      |> with_resolution([v_res, t_res, vu_res, tc_res])
      |> with_envelopes(module, mode, [
        {"value", v_res[:envelope]},
        {"_value_uncalibrated", vu_res[:envelope]}
      ])
    else
      :not_plottable
    end
  end

  # Only "value" is required; the module may lack the other parameters (they
  # were renamed between interface class versions). Missing ones plot empty.
  defp fetch_optional(param, mode, kind \\ :plain, opts \\ [])

  defp fetch_optional(nil, _mode, _kind, _opts),
    do: {[], [], %{aggregated: false, bucket_ms: nil}}

  defp fetch_optional(param, mode, :held, _opts), do: fetch_held_param_window(param, mode)
  defp fetch_optional(param, mode, :plain, opts), do: fetch_param_window(param, mode, opts)

  defp envelope_on_load?(_module, nil, _mode), do: false

  defp envelope_on_load?(module, param, mode),
    do: SecantService.PlotDB.envelope_on_load?(module, param, mode)

  @impl true
  def trace_updates(
        %{_param_dtype_modules: mods, option: opt} = _plot_map,
        datapoints,
        param_name
      ) do
    dtype_mod = Map.get(mods, param_name, Scalar)
    series_upds = dtype_mod.series_updates(opt, datapoints, param_name)
    %{seriesUpdates: series_upds}
  end
end
