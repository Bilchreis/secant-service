defmodule SecantService.PlotDB.Drivable do
  @behaviour SecantService.PlotDB.PlotSpec

  import SecantService.PlotDB.Builders

  @max_array_len 100

  @impl true
  def param_names, do: ["value", "target"]

  @impl true
  def plot(module, mode) do
    value_param = find_param(module, "value")

    if value_param do
      {v_val, v_ts} = fetch_param_data(value_param)
      unit = get_in(value_param.datainfo, ["unit"])

      case value_param.datainfo["type"] do
        "array" ->
          array_len = v_val |> List.first([]) |> length()

          if array_len > @max_array_len do
            :not_plottable
          else
            option = heatmap_option([heatmap_series(v_ts, v_val)], array_len, unit, mode)

            {:ok,
             %{
               plottable: true,
               plot_available: length(v_val) > 1,
               plot_type: :array_heatmap,
               option: option
             }}
          end

        "enum" ->
          members = value_param.datainfo["members"]
          target_param = find_param(module, "target")
          {t_val, t_ts} = fetch_param_data(target_param)

          series = [
            enum_series("value", v_ts, v_val, members, "value"),
            enum_series("target", t_ts, t_val, members, "target")
          ]

          option = enum_timeseries_option(series, members, "value", mode, ["target", "value"])
          {:ok, %{plottable: true, plot_available: length(v_val) > 1, option: option}}

        _ ->
          target_param = find_param(module, "target")
          {t_val, t_ts} = fetch_param_data(target_param)

          series = [
            scalar_line_series("value", v_ts, v_val),
            scalar_line_series("target", t_ts, t_val)
          ]

          option = timeseries_option(series, unit, mode)
          {:ok, %{plottable: true, plot_available: length(v_val) > 1, option: option}}
      end
    else
      :not_plottable
    end
  end
end
