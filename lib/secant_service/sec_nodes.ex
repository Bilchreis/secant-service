defmodule SecantService.SecNodes do
  @moduledoc """
  Domain for managing SECoP nodes and their metadata.
  """

  use Ash.Domain,
    otp_app: :secant_service

  alias SecantService.SecNodes.SecNode
  alias SecantService.DescribeMessageTransformer

  resources do
    resource SecantService.SecNodes.Command
    resource SecantService.SecNodes.Module
    resource SecantService.SecNodes.ParameterValueArrayBool
    resource SecantService.SecNodes.ParameterValueArrayDouble
    resource SecantService.SecNodes.ParameterValueArrayInt
    resource SecantService.SecNodes.ParameterValueArrayString
    resource SecantService.SecNodes.ParameterValueBool
    resource SecantService.SecNodes.ParameterValueDouble
    resource SecantService.SecNodes.ParameterValueInt
    resource SecantService.SecNodes.ParameterValueJson
    resource SecantService.SecNodes.ParameterValueString
    resource SecantService.SecNodes.Parameter
    resource SecantService.SecNodes.SecNode
  end

  @doc """
  Imports a SecantClient.NodeStatem state into the database.

  This is the primary high-level function for persisting SECoP node descriptive data.

  ## Parameters
  - `statem_state` - The state map from SecantClient.NodeStatem containing description and metadata

  ## Returns
  - `{:ok, sec_node}` - Successfully created SecNode record
  - `{:error, changeset}` - Validation or persistence error

  ## Examples

      iex> {:ok, state} = SecantClient.NodeStatem.get_state(pid)
      iex> SecantService.Ash.SecNodes.import_statem_state(state)
      {:ok, %SecNode{equipment_id: "sim_gas_dosing", ...}}
  """
  def import_statem_state(statem_state) do
    statem_state
    |> DescribeMessageTransformer.transform()
    |> then(fn prepared_data ->
      SecNode
      |> Ash.Changeset.for_create(:create, prepared_data)
      |> Ash.create()
    end)
  end
end
