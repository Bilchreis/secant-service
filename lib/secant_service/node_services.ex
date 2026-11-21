defmodule SecantService.NodeSupervisor do
  # Automatically defines child_spec/1
  require Logger
  use DynamicSupervisor

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

  @doc "Whether services run for a node (`{host, port}`) or a session (uuid)."
  def services_running?({_host, _port} = node_id), do: get_services_pid(node_id) != nil
  def services_running?(uuid), do: MapSet.member?(running_uuids(), uuid)

  @doc """
  The uuid of the SecNode record the running services of `node_id` were started
  from, or `nil` if no services are running.

  The uuid is the value of the services' Registry entry, so this never waits
  on a node process: it answers the same while a child is busy or restarting.
  """
  def running_uuid(node_id) do
    case Registry.lookup(Registry.NodeServices, node_id) do
      [{_pid, uuid}] -> uuid
      [] -> nil
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

  @doc "The uuids of all sessions that have running services."
  def running_uuids() do
    Registry.select(Registry.NodeServices, [{{:_, :_, :"$1"}, [], [:"$1"]}])
    |> MapSet.new()
  end
end

defmodule SecantService.NodeServices do
  use Supervisor
  require Logger

  @moduledoc """
  Supervisor for all processes related to a specific SEC Node, including:
  - NodeValues: Buffering and caching of incoming node values
  - DBWriter: Process responsible for writing node values to the database
  - PlotCache: collects live values and sends them to the dashboard plots in
    one batch every few seconds

  """

  def start_link(node_db) do
    Supervisor.start_link(__MODULE__, node_db,
      # the uuid is the entry's value: see NodeSupervisor.running_uuid/1
      name: {:via, Registry, {Registry.NodeServices, node_db.node_id, node_db.uuid}}
    )
  end

  @impl true
  def init(node_db) do
    Logger.info("Initializing NodeServices for #{inspect(node_db.node_id)}")

    children = [
      # Buffer process for this specific node
      {SecantService.NodeValues, node_db},

      # Batches live values for the dashboard plots
      {SecantService.PlotCache, node_db},

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
