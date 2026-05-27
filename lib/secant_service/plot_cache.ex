defmodule SecantService.PlotCacheSupervisor do
  use DynamicSupervisor
  require Logger
  alias SecantService.PlotCache

  def start_link(node_db) do
    DynamicSupervisor.start_link(__MODULE__, node_db,
      name: {:via, Registry, {Registry.PlotCacheSupervisor, node_db.node_id}}
    )
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_plot_cache(node_db) do
    node_id = node_db.node_id

    case Registry.lookup(Registry.PlotCacheSupervisor, node_id) do
      [{cache_supervisor, _value}] ->
        count =
          Enum.reduce(node_db.modules, 0, fn module, acc ->
            Enum.reduce(module.parameters, acc, fn parameter, inner_acc ->
              opts = %{
                node_id: node_id,
                module: module.name,
                parameter: parameter.name
              }

              DynamicSupervisor.start_child(cache_supervisor, {PlotCache, opts})
              inner_acc + 1
            end)
          end)

        Logger.info("Started #{count} plot cache(s) for node #{inspect(node_id)}")
        :ok

      [] ->
        Logger.error(
          "PlotCacheSupervisor not found for node #{inspect(node_id)}, skipping plot cache start"
        )

        {:error, :supervisor_not_found}
    end
  end
end

defmodule SecantService.PlotCacheDispatcher do
  use GenServer
  require Logger

  @client_pubsub_name :secant_client_pubsub

  def start_link(node_id) do
    GenServer.start_link(__MODULE__, node_id,
      name: {:via, Registry, {Registry.PlotCacheDispatcher, node_id}}
    )
  end

  @impl true
  def init(node_id) do
    values_pubsub_topic = "value_update:#{elem(node_id, 0)}:#{elem(node_id, 1)}"
    Phoenix.PubSub.subscribe(@client_pubsub_name, values_pubsub_topic)

    {:ok, %{node_id: node_id}}
  end

  @impl true
  def handle_info({:value_update, module, parameter, data_report}, state) do
    case Registry.lookup(Registry.PlotCache, {state.node_id, module, parameter}) do
      [{pid, _}] ->
        send(pid, {:value_update, module, parameter, data_report})

      [] ->
        # PlotCache not found, ignore
        :ok
    end

    {:noreply, state}
  end
end

defmodule SecantService.PlotCache do
  use GenServer
  require Logger

  @service_pubsub_name SecantService.PubSub
  @publish_interval 3000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts,
      name:
        {:via, Registry, {Registry.PlotCache, {opts[:node_id], opts[:module], opts[:parameter]}}}
    )
  end

  @impl true
  def init(%{node_id: node_id, module: module, parameter: parameter}) do
    state = %{
      node_id: node_id,
      module: module,
      parameter: parameter,
      data_cache: []
    }

    Process.send_after(self(), :publish_data, @publish_interval)

    {:ok, state}
  end

  @impl true
  def handle_info(
        {:value_update, module, parameter, data_report},
        %{module: module, parameter: parameter} = state
      ) do
    # This will only match if the incoming module and parameter match the ones in state
    data_cache = [data_report | state.data_cache]
    {:noreply, Map.put(state, :data_cache, data_cache)}
  end

  def handle_info({:value_update, module, parameter, data_report}, state) do
    # This catches updates for other module/parameter combinations (do nothing here)
    Logger.warning(
      "received value update for the wrong module and parameter: #{state.module} - #{state.parameter}, got #{inspect({module, parameter, data_report})}."
    )

    {:noreply, state}
  end

  def handle_info(:publish_data, state) do
    state =
      case state.data_cache do
        [] ->
          state

        data_cache ->
          # Publish the cached data
          Phoenix.PubSub.broadcast(
            @service_pubsub_name,
            "plot_data:#{elem(state.node_id, 0)}:#{elem(state.node_id, 1)}",
            {:plot_data, state.module, state.parameter, Enum.reverse(data_cache)}
          )

          Map.put(state, :data_cache, [])
      end

    Process.send_after(self(), :publish_data, @publish_interval)
    {:noreply, state}
  end
end
