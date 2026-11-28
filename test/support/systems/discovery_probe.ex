defmodule SecantServiceWeb.Systems.DiscoveryProbe do
  @moduledoc """
  Test system under the namespace `SecantServiceWeb.Systems` searches, so the
  tests see discovery find it. Its schema name matches no real node.
  """
  @behaviour SecantServiceWeb.SystemDefinition

  def system, do: "DiscoveryProbe"
  def versions, do: [0]
  def roles(0), do: %{"probe" => SecantServiceWeb.TestSystems.PlotOnly}
end
