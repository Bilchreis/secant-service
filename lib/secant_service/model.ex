defmodule SecantService.Model do
  require Logger
  alias SecantService.Model
  alias SEC_Node_Supervisor
  use Phoenix.Component

  alias NodeTable
  alias SecantService.NodeValues
  alias SecantService.NodeSupervisor

  # Define the struct at the top of the module
  defstruct [:active_nodes, :current_node, :values]

  @type t :: %__MODULE__{
          active_nodes: map(),
          current_node: map() | nil,
          values: map() | nil
        }

  @spec from_socket(Phoenix.LiveView.Socket.t()) :: t()
  def from_socket(socket) do
    %Model{
      active_nodes: socket.assigns.active_nodes,
      current_node: socket.assigns.current_node,
      values: socket.assigns.values
    }
  end

  @spec to_socket(Phoenix.LiveView.Socket.t(), t()) :: Phoenix.LiveView.Socket.t()
  def to_socket(socket, model) do
    socket
    |> assign(:active_nodes, model.active_nodes)
    |> assign(:current_node, model.current_node)
    |> assign(:values, model.values)
  end

  @spec get_initial_model() :: t()
  def get_initial_model() do
    active_nodes = SEC_Node_Supervisor.get_active_nodes()

    # Select only the relevant keys from each node
    active_nodes =
      Enum.reduce(active_nodes, %{}, fn {node_id, node}, acc ->
        node =
          Map.take(node, [
            :host,
            :port,
            :node_id,
            :equipment_id,
            :pubsub_topic,
            :state,
            :active,
            :uuid,
            :error
          ])

        Map.put(acc, node_id, node)
      end)

    %Model{
      active_nodes: active_nodes,
      current_node: nil,
      values: nil
    }
  end

  @spec get_default_node_id(t()) :: {String.t(), integer()} | nil
  def get_default_node_id(model) do
    if model.active_nodes == %{} do
      nil
    else
      # Any node with running services, so the dashboard doesn't open on a
      # node that never answered; otherwise an arbitrary one
      node_ids = Map.keys(model.active_nodes)

      Enum.find(node_ids, &NodeSupervisor.services_running?/1) || List.first(node_ids)
    end
  end

  @spec set_current_node(t(), nil | {String.t(), integer()}) :: t()
  def set_current_node(model, nil) do
    model
  end

  @spec set_current_node(t(), {String.t(), integer()}) :: t()
  def set_current_node(model, node_id) do
    current_node = Map.get(model.active_nodes, node_id)

    # Get the current node from the active nodes map
    model =
      if NodeSupervisor.services_running?(node_id) do
        {:ok, db_node} = NodeValues.get_node_db(node_id)

        {:ok, values} = NodeValues.get_values(node_id)

        model =
          model
          |> Map.put(:current_node, db_node)
          |> Map.put(:values, values)

        model
      else
        Logger.warning("Services for Node with UUID #{current_node[:uuid]} are not running yet.")
        model
      end

    model
  end
end
