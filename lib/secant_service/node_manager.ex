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
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:sync_nodes, state) do
    sync_nodes_safely()
    {:noreply, state}
  end

  @impl true
  def handle_info(:sync_nodes, state) do
    sync_nodes_safely()

    # Only the timer reschedules itself, so extra syncs don't multiply timers
    schedule_sync()

    {:noreply, state}
  end

  def handle_info({:new_node, _pubsub_topic, :connection_failed}, state) do
    {:noreply, state}
  end

  def handle_info({:new_node, _pubsub_topic, node_state}, state) do
    Logger.info("New node: #{node_state.equipment_id} #{node_state.host} (#{node_state.port})")

    sync_nodes_safely()
    {:noreply, state}
  end

  def handle_info({:description_change, _pubsub_topic, node_state}, state) do
    Logger.info("Description Change for node: #{node_state.equipment_id}")

    safely(fn -> ensure_node_services(node_state) end)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp schedule_sync do
    Process.send_after(self(), :sync_nodes, @check_interval)
  end

  defp sync_nodes_safely do
    Logger.info("Syncing nodes with database...")

    safely(fn -> sync_nodes_with_db(SEC_Node_Supervisor.get_active_nodes()) end)
  end

  defp safely(fun) do
    fun.()
  rescue
    e ->
      if is_struct(e, DBConnection.OwnershipError) or Exception.message(e) =~ "OwnershipError" do
        Logger.warning("NodeManager sync skipped (no DB connection available)")
      else
        Logger.error("NodeManager sync failed: #{Exception.message(e)}")
      end

      :error
  end

  defp sync_nodes_with_db(active_nodes) do
    Enum.each(active_nodes, fn {_node_id, node_state} -> ensure_node_services(node_state) end)

    # Stop Node Services for nodes that are no longer active
    active_node_ids = active_nodes |> Enum.map(fn {_, node} -> node.node_id end) |> MapSet.new()
    current_service_node_ids = NodeSupervisor.list_node_id_services() |> MapSet.new()

    MapSet.difference(current_service_node_ids, active_node_ids)
    |> Enum.each(fn node_id ->
      uuid = running_uuid(node_id)
      NodeSupervisor.stop_node_services(node_id)
      archive_node(uuid)
    end)
  end

  # Makes sure the services running for a node belong to its current
  # description (uuid). The running services are the source of truth: a node
  # that comes back with a changed description gets a new uuid, so the services
  # of the old one are stopped, the old database node is archived and the new
  # one is stored and started.
  #
  # A node that has not answered a describe yet (still connecting, or
  # discovered but unreachable) has nothing to store or serve, so it is left
  # alone until its description arrives.
  defp ensure_node_services(%{description: nil}), do: :ok

  defp ensure_node_services(node_state) do
    node_id = node_state.node_id
    running? = NodeSupervisor.services_running?(node_id)
    old_uuid = if running?, do: running_uuid(node_id)

    if old_uuid != node_state.uuid do
      if running? do
        Logger.info(
          "Node UUID changed from #{old_uuid} to #{node_state.uuid}, stopping node Services"
        )

        NodeSupervisor.stop_node_services(node_id)
        archive_node(old_uuid)
      end

      case upsert_node(node_state) do
        {:ok, node_db} ->
          Logger.info(
            "Starting Services for node: #{node_state.equipment_id} #{node_state.host}:#{node_state.port}"
          )

          NodeSupervisor.start_child(node_db)
          Task.start(fn -> SecantService.PlotCacheSupervisor.start_plot_cache(node_db) end)

        {:error, error} ->
          Logger.error("Failed to sync node: #{inspect(error)}")
      end
    end
  end

  defp upsert_node(node_state) do
    with {:ok, node} <-
           SecNode
           |> Ash.Changeset.for_create(:upsert, DescribeMessageTransformer.transform(node_state))
           |> Ash.create() do
      Logger.info("Synced node: #{node_state.equipment_id} #{node_state.host}:#{node_state.port}")

      Ash.get(SecNode, node.uuid)
    end
  end

  defp running_uuid(node_id) do
    case SecantService.NodeValues.get_node_db(node_id) do
      {:ok, node_db} -> node_db.uuid
      {:error, _} -> nil
    end
  end

  defp archive_node(nil), do: :ok

  defp archive_node(uuid) do
    with {:ok, %SecNode{state: :active} = node} <- Ash.get(SecNode, uuid),
         {:error, error} <- Ash.update(node, %{}, action: :archive) do
      Logger.warning("NodeManager: failed to archive node #{uuid}: #{inspect(error)}")
    else
      {:ok, %SecNode{state: :processed}} ->
        Logger.info("NodeManager: archived node #{uuid}")

      _ ->
        :ok
    end
  end
end
