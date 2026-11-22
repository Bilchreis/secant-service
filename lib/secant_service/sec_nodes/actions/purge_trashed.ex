defmodule SecantService.SecNodes.Actions.PurgeTrashed do
  @moduledoc """
  Deletes every trashed node now (the purge trigger only deletes those past
  the retention). Values go with them through the foreign keys.

  Node by node, so one failing node does not keep the others; the result is
  counted from what is left in the trash afterwards.
  """
  use Ash.Resource.Actions.Implementation

  require Logger

  alias SecantService.SecNodes.SecNode

  @impl true
  def run(_input, _opts, context) do
    trashed = Ash.Query.for_read(SecNode, :read_trashed, %{}, scope: context)
    total = Ash.count!(trashed, scope: context)

    result =
      Ash.bulk_destroy(trashed, :destroy, %{},
        strategy: :stream,
        return_errors?: true,
        scope: context
      )

    remaining = Ash.count!(trashed, scope: context)

    if remaining > 0 do
      Logger.warning(
        "Purge left #{remaining} trashed node(s): #{inspect(Enum.take(result.errors || [], 3))}"
      )
    end

    # a node trashed meanwhile can make the difference negative
    {:ok, %{success: max(total - remaining, 0), failure: remaining}}
  end
end
