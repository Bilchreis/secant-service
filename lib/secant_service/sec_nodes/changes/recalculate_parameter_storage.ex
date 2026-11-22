defmodule SecantService.SecNodes.Changes.RecalculateParameterStorage do
  @moduledoc """
  Change to calculate and update storage metrics (datapoint count and disk size)
  for a given Parameter by loading the calculated values from aggregates and
  persisting them to the stored attributes.

  This change is designed to be resilient - if calculations fail, it logs the
  error and keeps the old counts, so other changes aren't blocked.
  """

  use Ash.Resource.Change
  require Logger

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, &put_metrics(&1, Ash.Context.to_opts(context)))
  end

  defp put_metrics(changeset, opts) do
    parameter = changeset.data
    metrics = [:calculated_datapoint_count, :calculated_disk_size_bytes]

    case Ash.load(parameter, metrics, opts) do
      {:ok, loaded_parameter} ->
        changeset
        |> Ash.Changeset.force_change_attribute(
          :datapoint_count,
          loaded_parameter.calculated_datapoint_count
        )
        |> Ash.Changeset.force_change_attribute(
          :disk_size_bytes,
          loaded_parameter.calculated_disk_size_bytes
        )

      {:error, reason} ->
        Logger.warning(
          "Failed to calculate storage metrics for parameter #{parameter.id}: #{inspect(reason)}"
        )

        # keep the old counts, let the other changes proceed
        changeset
    end
  end
end
