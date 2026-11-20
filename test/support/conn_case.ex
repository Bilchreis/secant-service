defmodule SecantServiceWeb.ConnCase do
  @moduledoc """
  Case for tests that need a connection (controllers, LiveViews).

  With `node: true` in the module tags (`use SecantServiceWeb.ConnCase,
  node: true`) the node lifecycle setup of `SecantService.NodeCase` is used
  instead of a plain sandbox.
  """
  use ExUnit.CaseTemplate

  using opts do
    node_case =
      if Keyword.get(opts, :node, false) do
        quote do
          import SecantService.NodeFixtures
          alias SecantService.{NodeManager, NodeSupervisor, NodeValues, FakeNodeStatem}
          @moduletag node_case: true
        end
      end

    quote do
      @endpoint SecantServiceWeb.Endpoint

      use SecantServiceWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

      unquote(node_case)
    end
  end

  setup tags do
    if tags[:node_case] do
      SecantService.NodeCase.setup_node_manager(tags)
    else
      pid = Ecto.Adapters.SQL.Sandbox.start_owner!(SecantService.Repo, shared: not tags[:async])
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    end

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
