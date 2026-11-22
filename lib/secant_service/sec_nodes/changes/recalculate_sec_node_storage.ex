defmodule SecantService.SecNodes.Changes.RecalculateSecNodeStorage do
  @moduledoc """
  Recounts the stored datapoints and disk size of every parameter of a sec
  node. Used by `:finish_archiving` and `:refresh_storage`; the work runs when
  the action runs, not while the changeset is built.
  """

  use Ash.Resource.Change
  require Logger

  alias SecantService.SecNodes

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      recalculate_all_parameter_storage(changeset.data.uuid, scope: context)
      changeset
    end)
  end

  # `opts`: the action's context as the scope (actor, tenant, authorize?) of the nested calls
  defp recalculate_all_parameter_storage(sec_node_uuid, opts) do
    case SecNodes.parameters_of_node(sec_node_uuid, opts) do
      {:ok, parameters} ->
        {success_count, failure_count} =
          parameters
          |> Task.async_stream(
            fn parameter ->
              case SecNodes.recalculate_parameter_storage(parameter, opts) do
                {:ok, _updated_parameter} -> :ok
                {:error, reason} -> {:error, reason}
              end
            end,
            timeout: :infinity
          )
          |> Enum.reduce({0, 0}, fn
            {:ok, :ok}, {success, failure} -> {success + 1, failure}
            {:ok, {:error, _reason}}, {success, failure} -> {success, failure + 1}
            {:exit, _reason}, {success, failure} -> {success, failure + 1}
          end)

        Logger.info(
          "Recalculated parameter storage for sec node #{sec_node_uuid}: " <>
            "#{success_count} succeeded, #{failure_count} failed"
        )

      {:error, reason} ->
        Logger.warning(
          "Failed to load the parameters of sec node #{sec_node_uuid} for storage recalculation: #{inspect(reason)}"
        )
    end
  end
end
