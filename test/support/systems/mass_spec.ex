defmodule SecantServiceWeb.TestSystems.MassSpec do
  @moduledoc "Test system: a mass spectrum whose indexes are labelled from `_mass`."
  @behaviour SecantServiceWeb.SystemDefinition
  @behaviour SecantServiceWeb.SystemRole

  alias SecantService.PlotDB.ArrayPlot
  alias SecantService.PlotDB.LabelSource

  def system, do: "MassSpec"
  def versions, do: [0]
  def roles(0), do: %{"spectrometer" => __MODULE__}

  def required_parameters, do: ["_mass"]
  def card, do: nil

  def plot,
    do: %ArrayPlot{labels: %LabelSource{param: "_mass", template: "m/z {}"}, axis_name: "m/z"}
end
