defmodule SecantServiceWeb.TestSystems.PowerSupplyAlt do
  @moduledoc "Test system definition: a second `PowerSupply` definition, for configuration order."
  @behaviour SecantServiceWeb.SystemDefinition

  def system, do: "PowerSupply"
  def versions, do: [0, 1]
  def roles(_version), do: %{"current" => SecantServiceWeb.TestSystems.PlotOnly}
end
