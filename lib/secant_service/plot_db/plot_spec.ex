defmodule SecantService.PlotDB.PlotSpec do
  @doc """
  Fetch the required parameters from the module and build the full ECharts plot map.

  Returns `{:ok, plot_map}` on success, where `plot_map` contains at minimum:
    - `:plottable` (boolean)
    - `:plot_available` (boolean)
    - `:option` (ECharts option map)

  Returns `:not_plottable` when the module's data cannot be rendered.
  """
  @callback plot(
              module :: SecantService.SecNodes.Module.t(),
              mode :: :live | :historical
            ) :: {:ok, map()} | :not_plottable

  @doc "Parameter names this plot module reads, used for live-update routing."
  @callback param_names() :: [String.t()]
end
