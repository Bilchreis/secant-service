defmodule SecantService.PlotDB.PlotSpec do
  @doc """
  Fetch the required parameters from the module and build the full ECharts plot map.

  Returns `{:ok, plot_map}` on success, where `plot_map` contains at minimum:
    - `:plottable` (boolean)
    - `:plot_available` (boolean)
    - `:option` (ECharts option map)
    - `:_plot_spec_module` (the implementing module — used for live update dispatch)
    - `:_param_dtype_modules` (map of param name → DTypePlot module)

  Returns `:not_plottable` when the module's data cannot be rendered.
  """
  @callback plot(
              module :: SecantService.SecNodes.Module.t(),
              mode :: :live | :historical
            ) :: {:ok, map()} | :not_plottable

  @doc "Parameter names this plot module reads, used for live-update routing."
  @callback param_names() :: [String.t()]

  @doc """
  Convert a batch of live datapoints into the update payload sent to the JS chart hook.

  `plot_map` is the map returned by `plot/2`.
  `datapoints` is a list of `{raw_value, timestamp_ms}` tuples.
  `param_name` identifies which parameter the datapoints belong to.

  Returns a map with at least `:seriesUpdates` — a list of
  `%{seriesIndex: integer, data: [term]}` maps, one per affected ECharts series.
  ArrayHeatmap additionally includes `:arrayLen`.
  """
  @callback trace_updates(
              plot_map :: map,
              datapoints :: [{term, integer}],
              param_name :: String.t()
            ) :: map
end
