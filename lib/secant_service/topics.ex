defmodule SecantService.Topics do
  @moduledoc """
  PubSub topic names, built in one place so publishers and subscribers agree.

  A node is identified by `{host, port}`, with the host as a charlist (as
  SecantClient reports it) or a string.

  On `:secant_client_pubsub` (published by SecantClient):
    * `value_update/1`: raw value updates of a node
    * `error_update/1`: error reports of a node

  On `SecantService.PubSub`:
    * `processed_values/1`: values that changed, from `SecantService.NodeValues`
    * `plot_data/1`: batched plot points, from `SecantService.PlotCache`
    * `node_services/0`: services started and stopped, from `SecantService.NodeManager`
  """

  @type node_id :: {charlist() | String.t(), :inet.port_number()}

  @spec value_update(node_id) :: String.t()
  def value_update(node_id), do: "value_update:" <> address(node_id)

  @spec error_update(node_id) :: String.t()
  def error_update(node_id), do: "error_update:" <> address(node_id)

  @spec processed_values(node_id) :: String.t()
  def processed_values(node_id), do: "value_update:processed:" <> address(node_id)

  @spec plot_data(node_id) :: String.t()
  def plot_data(node_id), do: "plot_data:" <> address(node_id)

  @spec node_services() :: String.t()
  def node_services, do: "node_services"

  defp address({host, port}), do: "#{host}:#{port}"
end
