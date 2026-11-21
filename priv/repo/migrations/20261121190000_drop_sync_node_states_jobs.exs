defmodule SecantService.Repo.Migrations.DropSyncNodeStatesJobs do
  @moduledoc """
  The sync_node_states trigger is gone (the NodeManager ends sessions now);
  its queued jobs name worker modules that no longer exist.
  """
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM oban_jobs
    WHERE worker IN (
      'SecantService.SecNodes.SecNode.AshOban.Worker.SyncNodeStates',
      'SecantService.SecNodes.SecNode.AshOban.Scheduler.SyncNodeStates'
    )
    """)
  end

  def down, do: :ok
end
