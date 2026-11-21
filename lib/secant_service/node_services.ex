defmodule SecantService.NodeSupervisor do
  # Automatically defines child_spec/1
  require Logger
  use DynamicSupervisor
  alias SecantService.NodeValues

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_child(node_db) do
    opts = %{
      node_db: node_db
    }

    result = DynamicSupervisor.start_child(__MODULE__, {SecantService.NodeServices, opts})

    Logger.info("Started Node Services for Node : #{inspect(node_db.node_id)} #{inspect(result)}")

    result
  end

  def stop_node_services(node_id) do
    case get_services_pid(node_id) do
      nil ->
        Logger.info("No Services running found for ID: #{inspect(node_id)}")
        {:error, :not_found}

      pid ->
        Logger.info("Stopping Services for ID: #{inspect(node_id)}")
        DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  # node_id
  def services_running?({host, port}) do
    get_services_pid({host, port}) != nil
  end

  # uuid
  def services_running?(uuid) do
    MapSet.member?(list_uuid_services(), uuid)
  end

  @doc """
  The uuid of the SecNode record the running services of `node_id` were started
  from, or `nil` if no services are running (or they are mid-restart).
  """
  def running_uuid(node_id) do
    case NodeValues.get_node_db(node_id) do
      {:ok, node_db} -> node_db.uuid
      {:error, _} -> nil
    end
  end

  def get_services_pid(node_id) do
    case Registry.lookup(Registry.NodeServices, node_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def list_node_id_services() do
    Registry.select(Registry.NodeServices, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  def list_uuid_services() do
    list_node_id_services()
    |> Enum.reduce(MapSet.new(), fn node_id, acc ->
      case NodeValues.get_node_db(node_id) do
        {:ok, node_db} -> MapSet.put(acc, node_db.uuid)
        {:error, _} -> acc
      end
    end)
  end
end

defmodule SecantService.NodeServices do
  use Supervisor
  require Logger

  @moduledoc """
  Supervisor for all processes related to a specific SEC Node, including:
  - NodeValues: Buffering and caching of incoming node values
  - DBWriter: Process responsible for writing node values to the database
  - PlotCacheSupervisor: Supervisor for the plot cache processes of this node
    - this entails a process for each parameter of the SEC node, started with it
    - sends updates to the liveview plot components only every x seconds to reduce the number of updates

  """

  def start_link(node_db) do
    Supervisor.start_link(__MODULE__, node_db,
      name: {:via, Registry, {Registry.NodeServices, node_db.node_id}}
    )
  end

  @impl true
  def init(node_db) do
    Logger.info("Initializing NodeServices for #{inspect(node_db.node_id)}")

    children = [
      # Buffer process for this specific node
      {SecantService.NodeValues, node_db},

      # Supervisor for parameter plot caches (one per parameter)
      {SecantService.PlotCacheSupervisor, node_db},

      # Dispatcher process for plot cache updates
      {SecantService.PlotCacheDispatcher, node_db.node_id},

      # DB Writer process for this specific node
      {SecantService.NodeDBWriter, node_db}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def child_spec(opts) do
    %{
      id: opts.node_db.uuid,
      start: {__MODULE__, :start_link, [opts.node_db]},
      type: :supervisor,
      restart: :transient,
      shutdown: :infinity
    }
  end
end
