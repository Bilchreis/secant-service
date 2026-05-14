defmodule SecantService.SecNodes.Changes.RecalculateSecNodeStorage do
  @moduledoc """
  Change to recalculate storage for all parameters of a sec node and transition
  node state from `:processed` to `:archived` when applicable.
  """

  use Ash.Resource.Change
  require Logger

  alias SecantService.SecNodes.SecNode

  @impl true
  def change(changeset, _opts, _context) do
    recalculate_all_parameter_storage(changeset.data.uuid)

    current_state = Ash.Changeset.get_attribute(changeset, :state)

    if current_state == :processed do
      AshStateMachine.transition_state(changeset, :archived)
    else
      changeset
    end
  end

  defp recalculate_all_parameter_storage(sec_node_uuid) do
    case Ash.get(SecNode, sec_node_uuid, load: [modules: [:parameters]]) do
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
