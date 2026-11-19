defmodule SecantService.NodeCase do
  @moduledoc """
  Case for tests of the node lifecycle: DB sandbox in shared mode (node
  services run in their own processes), a NodeManager started for the test and
  all node services torn down afterwards.

  Tests using it must be `async: false`: node services, the NodeManager and
  the client registries are global.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import SecantService.NodeFixtures
      alias SecantService.{NodeManager, NodeSupervisor, NodeValues, FakeNodeStatem}
      alias SecantService.SecNodes.SecNode
    end
  end

  setup tags do
    setup_node_manager(tags)
  end

  def setup_node_manager(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(SecantService.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    # Registered after the sandbox, so it runs before the sandbox is stopped
    on_exit(&stop_all_node_services/0)

    start_supervised!({SecantService.NodeManager, periodic_sync: false})
    :ok
  end

  def stop_all_node_services do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(SecantService.NodeSupervisor) do
      DynamicSupervisor.terminate_child(SecantService.NodeSupervisor, pid)
    end
  end
end
