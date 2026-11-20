defmodule SecantService.FakeNodeStatem do
  @moduledoc """
  Stands in for a `SecantClient.NodeStatem` in tests.

  It registers under the node_id in `SecantClient.Registry.NodeStatem`, exactly like
  the real state machine, and answers `:get_state`. That is all the service
  side uses (`SecantClient.NodeSupervisor.get_active_nodes/0`, NodeManager), so tests
  control what the client "knows" about a node without any TCP connection.
  """
  use GenServer

  def start_link({node_id, state, opts}) do
    GenServer.start_link(__MODULE__, {state, opts},
      name: {:via, Registry, {SecantClient.Registry.NodeStatem, node_id}}
    )
  end

  def child_spec({node_id, _state, _opts} = arg) do
    %{id: {__MODULE__, node_id}, start: {__MODULE__, :start_link, [arg]}, restart: :temporary}
  end

  def put_state(node_id, state), do: GenServer.call(via(node_id), {:put_state, state})

  @doc "Make `:get_state` block for `ms`, like a state machine stuck in a handshake."
  def set_delay(node_id, ms), do: GenServer.call(via(node_id), {:set_delay, ms})

  defp via(node_id), do: {:via, Registry, {SecantClient.Registry.NodeStatem, node_id}}

  @impl true
  def init({state, opts}), do: {:ok, %{node_state: state, delay: Keyword.get(opts, :delay, 0)}}

  @impl true
  def handle_call(:get_state, _from, %{delay: delay} = s) do
    if delay > 0, do: Process.sleep(delay)
    {:reply, {:ok, s.node_state}, s}
  end

  def handle_call({:put_state, state}, _from, s), do: {:reply, :ok, %{s | node_state: state}}
  def handle_call({:set_delay, ms}, _from, s), do: {:reply, :ok, %{s | delay: ms}}
end
