defmodule SecantService.NodeManager do
  @moduledoc """
  Keeps the per-node services (`SecantService.NodeServices`) and the `SecNode`
  database records in line with the SEC nodes known to `secant_client`.

  Invariant: for every node that `secant_client` has described, the running
  NodeServices were started from the `SecNode` record whose uuid equals the
  client's *current* uuid for that node. `secant_client` issues a new uuid
  whenever the description of a node changes, so a uuid mismatch means the
  services hold an outdated description and are restarted from the new record.
  The record they replace is archived.

  When this fails (e.g. the database is briefly unavailable), all nodes are
  synced again after a short delay, backing off up to a minute between tries.

  The running services are the source of truth for "which uuid is live", so no
  separate bookkeeping is kept here that could drift out of sync.

  Whenever services for a node have been (re)started or stopped, this is
  broadcast on `SecantService.PubSub`, topic `services_topic/0`:

    * `{:node_services_ready, node_id, uuid}`
    * `{:node_services_stopped, node_id}`

  so that LiveViews can reload the node description and values.
  """
  use GenServer
  require Logger

  alias SecantService.SecNodes.SecNode
  alias SecantService.NodeSupervisor
  alias SecantService.DescribeMessageTransformer

  @pubsub_name :secant_client_pubsub
  @services_topic "node_services"
  # Periodic safety-net sync; events (new node, description change) are the primary trigger
  @check_interval :timer.minutes(10)
  @max_retry_interval :timer.minutes(1)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Topic on `SecantService.PubSub` where service lifecycle events are broadcast."
  def services_topic, do: @services_topic

  @doc "Trigger an asynchronous sync of all nodes."
  def sync_nodes do
    GenServer.cast(__MODULE__, :sync_nodes)
  end

  @doc "Sync all nodes and wait until it is done."
  def sync_nodes!(timeout \\ 60_000) do
    GenServer.call(__MODULE__, :sync_nodes, timeout)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(@pubsub_name, "descriptive_data_change")
    Phoenix.PubSub.subscribe(@pubsub_name, "new_node")

    if Keyword.get(opts, :periodic_sync, true) do
      send(self(), :periodic_sync)
    end

    # retry_delay: delay of the pending retry, nil when none is pending
    {:ok, %{retry_delay: nil}}
  end

  @impl true
  def handle_call(:sync_nodes, _from, state) do
    result = guarded(&sync_all/0)
    {:reply, result, maybe_retry(result, state)}
  end

  @impl true
  def handle_cast(:sync_nodes, state) do
    {:noreply, attempt(&sync_all/0, state)}
  end

  @impl true
  def handle_info(:periodic_sync, state) do
    state = attempt(&sync_all/0, state)
    Process.send_after(self(), :periodic_sync, @check_interval)
    {:noreply, state}
  end

  def handle_info(:retry_sync, %{retry_delay: delay} = state) do
    case guarded(&sync_all/0) do
      :ok ->
        {:noreply, %{state | retry_delay: nil}}

      _error ->
        next = min(delay * 2, @max_retry_interval)
        Logger.info("NodeManager: sync still failing, retrying in #{next} ms")
        Process.send_after(self(), :retry_sync, next)
        {:noreply, %{state | retry_delay: next}}
    end
  end

  def handle_info({:new_node, _pubsub_topic, :connection_failed}, state) do
    {:noreply, state}
  end

  def handle_info({:new_node, _pubsub_topic, node_state}, state) do
    Logger.info("New node: #{node_state.equipment_id} #{node_state.host} (#{node_state.port})")
    {:noreply, attempt(&sync_all/0, state)}
  end

  def handle_info({:description_change, _pubsub_topic, node_state}, state) do
    Logger.info("Description change for node: #{node_state.equipment_id}")

    # The message is a snapshot; when it is processed the node may already have
    # moved on to yet another description. Prefer the current state.
    current =
      case fetch_node_state(node_state.node_id) do
        {:ok, current} -> current
        :error -> node_state
      end

    {:noreply,
     attempt(fn -> if described?(current), do: ensure_services(current), else: :ok end, state)}
  end

  # Late replies of timed out get_state calls, and anything else
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp attempt(fun, state), do: maybe_retry(guarded(fun), state)

  # Schedules a full sync after a failed attempt, unless one is pending already.
  # The sync compares uuids of all nodes, so it also completes a failed
  # description change.
  defp maybe_retry(:ok, state), do: state
  defp maybe_retry(_error, %{retry_delay: delay} = state) when delay != nil, do: state

  defp maybe_retry(_error, state) do
    delay = Application.get_env(:secant_service, :node_retry_interval, 2_000)
    Logger.info("NodeManager: retrying sync in #{delay} ms")
    Process.send_after(self(), :retry_sync, delay)
    %{state | retry_delay: delay}
  end

  defp guarded(fun) do
    fun.()
  rescue
    e in [DBConnection.OwnershipError] ->
      Logger.warning("NodeManager: sync skipped (no DB connection available)")
      {:error, e}

    e ->
      if Exception.message(e) =~ "OwnershipError" do
        Logger.warning("NodeManager: sync skipped (no DB connection available)")
      else
        Logger.error("NodeManager: sync failed: #{Exception.format(:error, e, __STACKTRACE__)}")
      end

      {:error, e}
  end

  defp sync_all do
    Logger.info("Syncing nodes with database...")
    {node_states, unreachable} = fetch_node_states()

    results =
      node_states
      |> Map.values()
      |> Enum.filter(&described?/1)
      |> Enum.map(&ensure_services/1)

    # Stop services of nodes secant_client no longer knows about. Nodes whose
    # state machine did not answer in time are kept; they are still there.
    known = node_states |> Map.keys() |> MapSet.new() |> MapSet.union(unreachable)

    NodeSupervisor.list_node_id_services()
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Enum.each(&retire_services/1)

    if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, :incomplete}
  end

  # Only nodes that completed a describe can be stored and served.
  defp described?(node_state) do
    node_state[:description] != nil and node_state[:uuid] != nil
  end

  @doc false
  # Makes sure the services of `node_state.node_id` run from the record of
  # `node_state.uuid`, (re)starting them if needed.
  def ensure_services(node_state) do
    node_id = node_state.node_id
    uuid = node_state.uuid

    case NodeSupervisor.running_uuid(node_id) do
      ^uuid ->
        :ok

      old_uuid ->
        with {:ok, node_db} <- ensure_record(node_state) do
          if NodeSupervisor.services_running?(node_id) do
            Logger.info(
              "Node #{inspect(node_id)} changed uuid #{inspect(old_uuid)} -> #{uuid}, restarting services"
            )

            NodeSupervisor.stop_node_services(node_id)
          end

          if old_uuid, do: archive_record(old_uuid)

          start_services(node_db)
        end
    end
  end

  defp ensure_record(node_state) do
    case Ash.get(SecNode, node_state.uuid) do
      {:ok, node_db} ->
        {:ok, node_db}

      {:error, _not_found} ->
        transformed = DescribeMessageTransformer.transform(node_state)

        case SecNode |> Ash.Changeset.for_create(:upsert, transformed) |> Ash.create() do
          {:ok, node} ->
            Logger.info(
              "Stored node: #{node_state.equipment_id} #{node_state.host}:#{node_state.port}"
            )

            Ash.get(SecNode, node.uuid)

          {:error, error} ->
            Logger.error("Failed to store node #{inspect(node_state.node_id)}: #{inspect(error)}")
            {:error, error}
        end
    end
  end

  defp start_services(node_db) do
    case NodeSupervisor.start_child(node_db) do
      {:ok, _pid} ->
        broadcast({:node_services_ready, node_db.node_id, node_db.uuid})
        :ok

      {:error, reason} = error ->
        Logger.error(
          "Failed to start services for node #{inspect(node_db.node_id)}: #{inspect(reason)}"
        )

        error
    end
  end

  defp retire_services(node_id) do
    old_uuid = NodeSupervisor.running_uuid(node_id)
    NodeSupervisor.stop_node_services(node_id)
    if old_uuid, do: archive_record(old_uuid)
    broadcast({:node_services_stopped, node_id})
  end

  defp archive_record(uuid) do
    with {:ok, %SecNode{state: :active} = node} <- Ash.get(SecNode, uuid) do
      case Ash.update(node, %{}, action: :archive) do
        {:ok, _} ->
          Logger.info("NodeManager: archived node record #{uuid}")

        {:error, error} ->
          Logger.warning("NodeManager: failed to archive node #{uuid}: #{inspect(error)}")
      end
    end

    :ok
  end

  # A node state machine blocks while handshaking, don't let one node stall all others
  defp get_state_timeout do
    Application.get_env(:secant_service, :node_state_timeout, 5_000)
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(SecantService.PubSub, @services_topic, message)
  end

  # Like SEC_Node_Supervisor.get_active_nodes/0, but one slow or dying node
  # state machine can neither block nor crash the sync of all others.
  # Returns the states by node_id and the set of node_ids that did not answer.
  defp fetch_node_states do
    Registry.select(Registry.SEC_Node_Statem, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.reduce({%{}, MapSet.new()}, fn {node_id, pid}, {states, unreachable} ->
      case get_state(pid) do
        {:ok, state} -> {Map.put(states, state.node_id, state), unreachable}
        :gone -> {states, unreachable}
        :error -> {states, MapSet.put(unreachable, node_id)}
      end
    end)
  end

  defp fetch_node_state(node_id) do
    case Registry.lookup(Registry.SEC_Node_Statem, node_id) do
      [{pid, _}] ->
        case get_state(pid) do
          {:ok, state} -> {:ok, state}
          _ -> :error
        end

      [] ->
        :error
    end
  end

  # :gone when the state machine already exited (the Registry unregisters
  # asynchronously, so a just-stopped node can still be listed for a moment).
  defp get_state(pid) do
    case :gen_statem.call(pid, :get_state, get_state_timeout()) do
      {:ok, state} -> {:ok, state}
      _ -> :error
    end
  catch
    :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] ->
      :gone

    :exit, reason ->
      Logger.warning("NodeManager: could not get node state: #{inspect(reason)}")
      :error
  end
end
