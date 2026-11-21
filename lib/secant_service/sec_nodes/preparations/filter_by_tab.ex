defmodule SecantService.SecNodes.Preparations.FilterByTab do
  @moduledoc """
  Filters the data browser listing by tab: the `:state_filter` argument is
  `:all`, `:favourite`, or a node state.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    case Ash.Query.get_argument(query, :state_filter) do
      :all -> query
      :favourite -> Ash.Query.filter(query, favourite == true)
      state -> Ash.Query.filter(query, state == ^state)
    end
  end
end
