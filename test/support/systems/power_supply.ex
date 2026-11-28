defmodule SecantServiceWeb.TestSystems.PowerSupply do
  @moduledoc "Test system definition: the proposed `PowerSupply` schema, version 0."
  @behaviour SecantServiceWeb.SystemDefinition

  alias SecantServiceWeb.TestSystems.PowerSupply

  def system, do: "PowerSupply"
  def versions, do: [0]

  def roles(0),
    do: %{"current" => PowerSupply.Current, "voltage" => PowerSupply.Voltage}
end
