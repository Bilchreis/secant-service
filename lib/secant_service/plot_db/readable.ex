defmodule SecantService.PlotDB.Readable do
  @behaviour SecantService.PlotDB.PlotSpec

  import SecantService.PlotDB.Builders

  @max_array_len 100

  @impl true
  def param_names, do: ["value"]

  @impl true
  def plot(module, mode) do
    value_param = find_param(module, "value")

    if value_param do
      {val, ts} = fetch_param_data(value_param)
      unit = get_in(value_param.datainfo, ["unit"])

      case value_param.datainfo["type"] do
        "array" ->
          array_len = val |> List.first([]) |> length()

          if array_len > @max_array_len do
            :not_plottable
          else
            option =
              heatmap_option([heatmap_series(ts, val)], array_len, unit, mode)

            {:ok,
             %{
               plottable: true,
               plot_available: length(val) > 1,
               plot_type: :array_heatmap,
               option: option
             }}
          end

        "enum" ->
          members = value_param.datainfo["members"]
          option = enum_timeseries_option([enum_series("value", ts, val, members)], members, "value", mode)
          {:ok, %{plottable: true, plot_available: length(val) > 1, option: option}}

        _ ->
          series = [scalar_line_series("value", ts, val)]
          option = timeseries_option(series, unit, mode)
          {:ok, %{plottable: true, plot_available: length(val) > 1, option: option}}
      end
    else
      :not_plottable
    end
  end
end
