defmodule SecantService.E2E.NodeReconnectTest do
  @moduledoc """
  End to end: a real SEC node (the frappy demo cryostat) goes away and comes
  back, and the service and dashboard have to follow.
  """
  use SecantService.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SecantService.FrappyServer
  alias SecantService.NodeManager
  alias SecantService.NodeSupervisor
  alias SecantService.NodeValues
  alias SecantService.SecNodes.SecNode

  @endpoint SecantServiceWeb.Endpoint

  @moduletag :frappy
  @moduletag :tmp_dir
  @moduletag timeout: 180_000

  @host ~c"127.0.0.1"
  # The client retries a lost connection every 5 s
  @reconnect_timeout 60_000

  setup %{tmp_dir: tmp_dir} do
    tcp_port = FrappyServer.free_tcp_port()
    node_id = {@host, tcp_port}

    frappy = FrappyServer.start(tmp_dir, tcp_port, equipment_id: "cryo_before")
    # Tracks the running frappy across restarts; not linked, so it is still
    # there when on_exit runs after the test process died
    {:ok, agent} = Agent.start(fn -> frappy end)

    # Runs before the DataCase hands back the database connection
    on_exit(fn ->
      stop_client(node_id)
      NodeSupervisor.stop_node_services(node_id)
      # Lets the manager finish any sync still using the database
      :sys.get_state(NodeManager)
    end)

    on_exit(fn ->
      FrappyServer.stop(Agent.get(agent, & &1))
      Agent.stop(agent)
    end)

    {:ok, _pid} =
      SEC_Node_Supervisor.start_child(%{
        host: @host,
        port: tcp_port,
        manual: true,
        reconnect_backoff: 5000
      })

    uuid = wait_for_running_uuid(node_id, fn uuid -> uuid != nil end)

    %{node_id: node_id, tcp_port: tcp_port, uuid: uuid, frappy: frappy, agent: agent}
  end

  test "a node that returns with a changed description is served as a new node", ctx do
    assert %SecNode{state: :active, equipment_id: "cryo_before"} = Ash.get!(SecNode, ctx.uuid)

    {:ok, view, _html} = live(build_conn(), "/dashboard?node=127.0.0.1:#{ctx.tcp_port}")
    assert has_element?(view, "#uuid-#{ctx.uuid}")

    restart_frappy(ctx, equipment_id: "cryo_after", description: "a changed description")

    new_uuid =
      wait_for_running_uuid(ctx.node_id, fn uuid -> uuid not in [nil, ctx.uuid] end)

    assert %SecNode{state: :active, equipment_id: "cryo_after"} = Ash.get!(SecNode, new_uuid)
    refute Ash.get!(SecNode, ctx.uuid).state == :active

    # the new node records values
    FrappyServer.wait_until(10_000, "a value of the new node", fn ->
      match?({:ok, %{"cryo" => %{"value" => _}}}, NodeValues.get_values(ctx.node_id))
    end)

    # the open dashboard switches over to the new node
    FrappyServer.wait_until(10_000, "the dashboard to show the new node", fn ->
      has_element?(view, "#uuid-#{new_uuid}")
    end)

    refute has_element?(view, "#uuid-#{ctx.uuid}")
  end

  test "a node that reconnects with the same description stays the same node", ctx do
    services_pid = NodeSupervisor.get_services_pid(ctx.node_id)

    FrappyServer.stop(ctx.frappy)
    wait_for_client_state(ctx.node_id, :disconnected)

    # a sync during the outage must leave the node alone
    NodeManager.sync_nodes()
    :sys.get_state(NodeManager)

    assert NodeSupervisor.get_services_pid(ctx.node_id) == services_pid
    assert Ash.get!(SecNode, ctx.uuid).state == :active

    frappy = FrappyServer.start(ctx.tmp_dir, ctx.tcp_port, equipment_id: "cryo_before")
    Agent.update(ctx.agent, fn _ -> frappy end)

    wait_for_client_state(ctx.node_id, :initialized)
    NodeManager.sync_nodes()
    :sys.get_state(NodeManager)

    assert client_state(ctx.node_id).uuid == ctx.uuid
    assert NodeSupervisor.get_services_pid(ctx.node_id) == services_pid
    assert Ash.get!(SecNode, ctx.uuid).state == :active
  end

  defp restart_frappy(ctx, opts) do
    FrappyServer.stop(ctx.frappy)
    frappy = FrappyServer.start(ctx.tmp_dir, ctx.tcp_port, opts)
    Agent.update(ctx.agent, fn _ -> frappy end)
    frappy
  end

  defp wait_for_running_uuid(node_id, accept?) do
    FrappyServer.wait_until(@reconnect_timeout, "node services of #{inspect(node_id)}", fn ->
      with true <- NodeSupervisor.services_running?(node_id),
           {:ok, node_db} <- NodeValues.get_node_db(node_id),
           true <- accept?.(node_db.uuid) do
        node_db.uuid
      else
        _ -> nil
      end
    end)
  end

  defp wait_for_client_state(node_id, expected) do
    FrappyServer.wait_until(@reconnect_timeout, "client state #{expected}", fn ->
      client_state(node_id).state == expected
    end)
  end

  defp client_state(node_id) do
    [{pid, _}] = Registry.lookup(Registry.SEC_Node_Statem, node_id)
    {:ok, state} = SEC_Node_Statem.get_state(pid)
    state
  end

  defp stop_client(node_id) do
    case Registry.lookup(Registry.SEC_Node_Services, node_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(SEC_Node_Supervisor, pid)
      [] -> :ok
    end
  end
end
