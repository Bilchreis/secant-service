defmodule SecantService.SecNodes.Changes.RecalculateParameterStorage do
  @moduledoc """
  Change to calculate and update storage metrics (datapoint count and disk size)
  for a given Parameter by loading the calculated values from aggregates and
  persisting them to the stored attributes.

  This change is designed to be resilient - if calculations fail, it logs the error
  but allows the changeset to proceed so other changes aren't blocked.
  """

  use Ash.Resource.Change
  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    parameter = changeset.data

    # Load the parameter with calculations
    case load_calculated_metrics(parameter) do
      {:ok, loaded_parameter} ->
        changeset
        |> Ash.Changeset.change_attribute(
          :datapoint_count,
          loaded_parameter.calculated_datapoint_count
        )
        |> Ash.Changeset.change_attribute(
          :disk_size_bytes,
          loaded_parameter.calculated_disk_size_bytes
        )

      {:error, reason} ->
        Logger.warning(
          "Failed to calculate storage metrics for parameter #{parameter.id}: #{inspect(reason)}"
        )

        # Return changeset unchanged - allow other changes to proceed
        changeset
    end
  end

  defp load_calculated_metrics(parameter) do
    try do
      # Load the parameter with the calculations
      loaded =
        parameter
        |> Ash.load!([:calculated_datapoint_count, :calculated_disk_size_bytes])

      {:ok, loaded}
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end
end
