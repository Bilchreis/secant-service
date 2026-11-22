defmodule SecantService.SecNodes.Calculations.NodeId do
  @moduledoc """
  The node's address as `secant_client` keys it: `{host_charlist, port}`.
  Loads `host` and `port` itself, so it also works on a query that selects
  other fields.
  """

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:host, :port]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, &{String.to_charlist(&1.host), &1.port})
  end
end
