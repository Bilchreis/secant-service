defmodule SecantService.PlotDB.Acquisition do
  @behaviour SecantService.PlotDB.PlotSpec

  @impl true
  defdelegate plot(module, mode), to: SecantService.PlotDB.Readable

  @impl true
  defdelegate param_names(), to: SecantService.PlotDB.Readable

  @impl true
  defdelegate trace_updates(plot_map, datapoints, param_name), to: SecantService.PlotDB.Readable
end
