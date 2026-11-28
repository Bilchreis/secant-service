defmodule SecantServiceWeb.TestSystems.MissingMass do
  @moduledoc """
  Test system: a lines plot whose only trace picks the `spectrum` element of
  mass 29, which a module may not have: the plot then falls back.
  """
  @behaviour SecantServiceWeb.SystemDefinition
  @behaviour SecantServiceWeb.SystemRole

  alias SecantService.PlotDB.LabelSource
  alias SecantService.PlotDB.LinesPlot
  alias SecantService.PlotDB.Trace

  def system, do: "MissingMass"
  def versions, do: [0]
  def roles(0), do: %{"spectrometer" => __MODULE__}

  def required_parameters, do: ["_mass"]
  def card, do: nil

  def plot do
    %LinesPlot{
      traces: [%Trace{param: "spectrum", pick: {:match, %LabelSource{param: "_mass"}, 29}}]
    }
  end
end
