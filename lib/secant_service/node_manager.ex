defmodule SecantService.NodeManager do
  use GenServer
  require Logger
  alias SecantService.SecNodes.SecNode
  alias SecantService.NodeSupervisor
  alias SEC_Node_Supervisor
  alias SecantService.NodeSupervisor
  alias SecantService.DescribeMessageTransformer

  @pubsub_name :secant_client_pubsub
  # Check for node changes every minute
  @check_interval 1000 * 60 * 10

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_stored_nodes do
    GenServer.call(__MODULE__, :get_stored_nodes)
  end

  def sync_nodes do
    GenServer.cast(__MODULE__, :sync_nodes)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Initial sync of nodes from SEC_Node_Supervisor
    Phoenix.PubSub.subscribe(@pubsub_name, "descriptive_data_change")
    Phoenix.PubSub.subscribe(@pubsub_name, "new_node")

    send(self(), :sync_nodes)
    {:ok, %{nodes: %{}, subscriptions: %{}}}
  end

  @impl true
  def handle_call(:get_stored_nodes, _from, state) do
    {:reply, state.nodes, state}
  end

  @impl true
  def handle_cast(:sync_nodes, state) do
    Logger.info("Syncing nodes with database...")

    updated_state =
      try do
        # Get active nodes from supervisor
        active_nodes = SEC_Node_Supervisor.get_active_nodes()

        # Store nodes in database and subscribe to updates
        sync_nodes_with_db(active_nodes, state)
      rescue
        _e in [DBConnection.OwnershipError] ->
          Logger.warning("NodeManager sync skipped (no DB connection available)")
          state

        e ->
          if Exception.message(e) =~ "OwnershipError" do
            Logger.warning("NodeManager sync skipped (no DB connection available)")
          else
            Logger.error("NodeManager sync failed: #{Exception.message(e)}")
          end

          state
      end

    # Schedule next sync
    schedule_sync()

    {:noreply, updated_state}
  end

  @impl true
  def handle_info(:sync_nodes, state) do
    # Same as handle_cast but triggered by timer
    handle_cast(:sync_nodes, state)
  end

  def handle_info({:conn_state, _pubsub_topic, _active}, state) do
    # TODO

    {:noreply, state}
  end

  def handle_info({:state_change, pubsub_topic, _node_state}, state) do
    Logger.info("new node status: #{pubsub_topic} #{state.state}")

    {:noreply, state}
  end

  def handle_info({:new_node, _pubsub_topic, :connection_failed}, state) do
    {:noreply, state}
  end

  def handle_info({:new_node, _pubsub_topic, node_state}, state) do
    Logger.info("New node: #{node_state.equipment_id} #{node_state.host} (#{node_state.port})")

    handle_cast(:sync_nodes, state)
    {:noreply, state}
  end

  def handle_info({:description_change, _pubsub_topic, node_state}, state) do
    # Handle node description changes
    Logger.info("Description Change for node: #{node_state.equipment_id}")

    # Find the old UUID if present
    old_uuid = find_old_uuid(state.nodes, node_state.node_id)

    # If we have an old UUID and it's different, stop the old writer
    state =
      if old_uuid && old_uuid != node_state.uuid do
        Logger.info(
          "Node UUID changed from #{old_uuid} to #{node_state.uuid}, stopping node Services"
        )

        NodeSupervisor.stop_node_services(node_state.node_id)

        transformed_node_state = DescribeMessageTransformer.transform(node_state)

        case SecNode
             |> Ash.Changeset.for_create(:upsert, transformed_node_state)
             |> Ash.create() do
          {:ok, node} ->
            Logger.info(
              "Synced node: #{node_state.equipment_id} #{node_state.host}:#{node_state.port}"
            )

            node_db = Ash.get!(SecNode, node.uuid)
            Logger.debug("publish new node added at: #{node_db.uuid}")

            updated_nodes = Map.put(state.nodes, node_state.node_id, node_state)
            # Start a new writer

            NodeSupervisor.start_child(node_db)
            Task.start(fn -> SecantService.PlotCacheSupervisor.start_plot_cache(node_db) end)
            %{state | nodes: updated_nodes}

          {:error, changeset} ->
            Logger.error("Failed to sync node: #{inspect(changeset.errors)}")
            state
        end
      else
        state
      end

    {:noreply, state}
  end

  # Helper to find a node's old UUID
  defp find_old_uuid(nodes, node_id) do
    Map.get(nodes, node_id)
    |> case do
      nil -> nil
      node -> node.uuid
    end
  end

  # Private functions

  defp schedule_sync do
    Process.send_after(self(), :sync_nodes, @check_interval)
  end

  defp sync_nodes_with_db(active_nodes, state) do
    # Store/update nodes in database using upsert
    uuids = Enum.map(active_nodes, fn {_node_id, node_state} -> node_state.uuid end)

    uuids_in_db =
      SecNode
      |> Ash.Query.for_read(:exists_by_uuids, %{uuids: uuids})
      |> Ash.read!()
      |> Enum.map(fn node -> node.uuid end)
      |> MapSet.new()

    result =
      Enum.reduce(active_nodes, %{}, fn {node_id, node_state}, acc ->
        if not MapSet.member?(uuids_in_db, node_state.uuid) do
          transformed_node_state = DescribeMessageTransformer.transform(node_state)

          case SecNode
               |> Ash.Changeset.for_create(:upsert, transformed_node_state)
               |> Ash.create() do
            {:ok, _node} ->
              Logger.info(
                "Synced node: #{node_state.equipment_id} #{node_state.host}:#{node_state.port}"
              )

              Map.put(acc, node_id, node_state)

            {:error, changeset} ->
              Logger.error("Failed to sync node: #{inspect(changeset.errors)}")
              acc
          end
        else
          acc
        end
      end)

    # Start node Services for active nodes that don't have one
    Enum.each(active_nodes, fn {_node_id, node_state} ->
      if not NodeSupervisor.services_running?(node_state.node_id) do
        Logger.info(
          "Starting Services for node: #{node_state.equipment_id} #{node_state.host}:#{node_state.port}"
        )

        Task.start(fn ->
          node_db = Ash.get!(SecNode, node_state.uuid)
          NodeSupervisor.start_child(node_db)
          Task.start(fn -> SecantService.PlotCacheSupervisor.start_plot_cache(node_db) end)
        end)
      end
    end)

    # Stop Node Services for nodes that are no longer active
    active_node_ids = active_nodes |> Enum.map(fn {_, node} -> node.node_id end) |> MapSet.new()
    current_service_node_ids = NodeSupervisor.list_node_id_services() |> MapSet.new()

    # Writers to stop: those that exist but aren't in active nodes
    MapSet.difference(current_service_node_ids, active_node_ids)
    |> Enum.each(fn node_id ->
      NodeSupervisor.stop_node_services(node_id)

      # Archive the node in the database
      {host_charlist, port} = node_id
      host = List.to_string(host_charlist)

      case SecNode
           |> Ash.Query.filter_input(%{
             host: %{eq: host},
             port: %{eq: port},
             state: %{eq: :active}
           })
           |> Ash.read_one() do
        {:ok, %SecNode{} = node} ->
          case Ash.update(node, %{}, action: :archive) do
            {:ok, _} ->
              Logger.info("NodeManager: archived disconnected node #{host}:#{port}")

            {:error, error} ->
              Logger.warning(
                "NodeManager: failed to archive node #{host}:#{port}: #{inspect(error)}"
              )
          end

        _ ->
          :ok
      end
    end)

    old_nodes = state.nodes

    # Update statenode
    merged_nodes =
      Map.merge(old_nodes, result, fn _key, new_node, _old_node -> new_node end)
      |> keep_common_keys(active_nodes)

    %{state | nodes: merged_nodes}
  end

  defp keep_common_keys(map1, map2) do
    Map.filter(map1, fn {key, _value} -> Map.has_key?(map2, key) end)
  end
end
