defmodule SecantServiceWeb.TestSystems.MassTrend do
  @moduledoc "Test system: lines of the spectrum elements of the masses 28 and 44."
  @behaviour SecantServiceWeb.SystemDefinition
  @behaviour SecantServiceWeb.SystemRole

  alias SecantService.PlotDB.LabelSource
  alias SecantService.PlotDB.LinesPlot
  alias SecantService.PlotDB.Trace

  def system, do: "MassTrend"
  def versions, do: [0]
  def roles(0), do: %{"spectrometer" => __MODULE__}

  def required_parameters, do: ["_mass"]
  def card, do: nil

  def plot do
    mass = %LabelSource{param: "_mass", template: "m/z {}"}

    %LinesPlot{
      traces:
        for m <- [28, 44] do
          %Trace{param: "value", pick: {:match, mass, m}, label: mass}
        end
    }
  end
end
