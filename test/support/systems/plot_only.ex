defmodule SecantServiceWeb.TestSystems.PlotOnly do
  @moduledoc "Test role: a plot of `value` and no card."
  @behaviour SecantServiceWeb.SystemRole

  alias SecantService.PlotDB.LinesPlot
  alias SecantService.PlotDB.Trace

  def required_parameters, do: []
  def card, do: nil
  def plot, do: %LinesPlot{traces: [%Trace{param: "value"}]}
end
