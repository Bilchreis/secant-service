defmodule SecantService.PlotCache do
  @moduledoc """
  Collects the live values of one node for the dashboard plots and publishes
  them in one batch every 3 s, so a chart is updated a few times per
  minute instead of on every reading.

  One process per node: it subscribes to the node's value topic itself and
  keeps the readings of all parameters of the description in one buffer.
  The batch is broadcast as `{:plot_data, [{module, parameter, reports}]}` on
  `SecantService.Topics.plot_data/1`, reports oldest first.

  When recording of the node stops or resumes (`SecantService.RecordingTracker`
  calls `recording/3`), the buffered batch is published first and then
  `{:recording, :stopped | :resumed, ms}` on the same topic, so a plot gets
  the readings from before a stop before the stop itself.
  """
  use GenServer

  alias SecantService.Topics

  @client_pubsub :secant_client_pubsub
  @service_pubsub SecantService.PubSub
  @publish_interval 3000

  def start_link(node_db) do
    GenServer.start_link(__MODULE__, node_db,
      name: {:via, Registry, {Registry.PlotCache, node_db.node_id}}
    )
  end

  @doc "The `{module, parameter}` pairs this cache collects. For tests and debugging."
  def parameters(node_id), do: call(node_id, :parameters)

  @doc "Publish the buffered readings now instead of at the next interval."
  def flush(node_id), do: call(node_id, :flush)

  @doc """
  Recording of the node stopped or resumed at `ms` (Unix milliseconds).
  Published after the readings buffered so far. Without a running cache (it
  is the process that crashed), published at once: its buffer is gone anyway.
  """
  def recording(node_id, kind, ms) when kind in [:stopped, :resumed] do
    case Registry.lookup(Registry.PlotCache, node_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:recording, kind, ms})

      [] ->
        Phoenix.PubSub.broadcast(
          @service_pubsub,
          Topics.plot_data(node_id),
          {:recording, kind, ms}
        )
    end
  end

  defp call(node_id, msg) do
    case Registry.lookup(Registry.PlotCache, node_id) do
      [{pid, _}] -> GenServer.call(pid, msg)
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def init(node_db) do
    Phoenix.PubSub.subscribe(@client_pubsub, Topics.value_update(node_db.node_id))
    Process.send_after(self(), :publish, @publish_interval)

    known =
      for module <- node_db.modules, parameter <- module.parameters, into: MapSet.new() do
        {module.name, parameter.name}
      end

    {:ok, %{topic: Topics.plot_data(node_db.node_id), known: known, buffer: %{}}}
  end

  @impl true
  def handle_info({:value_update, module, parameter, data_report}, state) do
    key = {module, parameter}

    if MapSet.member?(state.known, key) do
      {:noreply,
       %{state | buffer: Map.update(state.buffer, key, [data_report], &[data_report | &1])}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:publish, state) do
    Process.send_after(self(), :publish, @publish_interval)
    {:noreply, publish(state)}
  end

  # Only value updates are expected on the topic; ignore anything else.
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast({:recording, kind, ms}, state) do
    state = publish(state)
    Phoenix.PubSub.broadcast(@service_pubsub, state.topic, {:recording, kind, ms})
    {:noreply, state}
  end

  @impl true
  def handle_call(:parameters, _from, state), do: {:reply, state.known, state}
  def handle_call(:flush, _from, state), do: {:reply, :ok, publish(state)}

  defp publish(%{buffer: buffer} = state) when map_size(buffer) == 0, do: state

  defp publish(state) do
    batch =
      for {{module, parameter}, reports} <- state.buffer do
        {module, parameter, Enum.reverse(reports)}
      end

    Phoenix.PubSub.broadcast(@service_pubsub, state.topic, {:plot_data, batch})
    %{state | buffer: %{}}
  end
end
