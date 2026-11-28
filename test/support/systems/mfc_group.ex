defmodule SecantServiceWeb.TestSystems.MfcGroup do
  @moduledoc """
  Test system: a mass flow controller group whose `value` is a struct of
  `composition` (%), `gas_list` and `total_flow`.
  """
  @behaviour SecantServiceWeb.SystemDefinition
  @behaviour SecantServiceWeb.SystemRole

  alias SecantService.PlotDB.LabelSource
  alias SecantService.PlotDB.LinesPlot
  alias SecantService.PlotDB.Trace

  def system, do: "MfcGroup"
  def versions, do: [0]
  def roles(0), do: %{"group" => __MODULE__}

  def required_parameters, do: ["value"]
  def card, do: nil

  def plot do
    %LinesPlot{
      traces: [
        %Trace{
          param: "value",
          path: ["composition"],
          pick: :each,
          label: %LabelSource{path: ["gas_list"]}
        },
        %Trace{param: "value", path: ["total_flow"], axis: 1}
      ]
    }
  end
end
