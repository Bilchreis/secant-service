defmodule SecantService.SecNodes.Changes.RecalculateSecNodeStorage do
  @moduledoc """
  Recounts the stored datapoints and disk size of every parameter of a sec
  node. Used by `:finish_archiving` and `:refresh_storage`; the work runs when
  the action runs, not while the changeset is built.
  """

  use Ash.Resource.Change
  require Logger

  alias SecantService.SecNodes.SecNode

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      recalculate_all_parameter_storage(changeset.data.uuid)
      changeset
    end)
  end

  defp recalculate_all_parameter_storage(sec_node_uuid) do
    case Ash.get(SecNode, sec_node_uuid, load: [modules: [:parameters]], authorize?: false) do
      {:ok, sec_node} ->
        parameters =
          sec_node.modules
          |> Enum.flat_map(& &1.parameters)

        {success_count, failure_count} =
          parameters
          |> Task.async_stream(
            fn parameter ->
              case Ash.update(parameter, %{}, action: :recalculate_storage) do
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
          "Failed to load sec node #{sec_node_uuid} for parameter storage recalculation: #{inspect(reason)}"
        )
    end
  end
end
