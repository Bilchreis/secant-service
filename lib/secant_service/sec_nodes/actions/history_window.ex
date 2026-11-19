defmodule SecantService.SecNodes.Actions.HistoryWindow do
  @moduledoc """
  Runs the `:history_window` and `:history_resolution` actions of
  `SecantService.SecNodes.Parameter`. The queries are in
  `SecantService.PlotDB.History`.
  """

  use Ash.Resource.Actions.Implementation

  alias SecantService.PlotDB.History
  alias SecantService.SecNodes.Parameter

  @impl true
  def run(input, _opts, _context) do
    %{parameter_id: id} = args = input.arguments
    opts = args |> Map.take([:max_raw, :max_buckets]) |> Enum.reject(&is_nil(elem(&1, 1)))

    with {:ok, parameter} <- Ash.get(Parameter, id),
         :ok <- numeric(parameter) do
      from_ms = Map.get(args, :from_ms)
      to_ms = Map.get(args, :to_ms)

      case input.action.name do
        :history_window -> {:ok, History.window(parameter, from_ms, to_ms, opts)}
        :history_resolution -> {:ok, History.resolution(parameter, from_ms, to_ms, opts)}
      end
    end
  end

  defp numeric(parameter) do
    if History.numeric?(parameter) do
      :ok
    else
      {:error,
       Ash.Error.Invalid.exception(
         errors: [
           Ash.Error.Changes.InvalidArgument.exception(
             field: :parameter_id,
             message: "is not a numeric parameter (double, int or scaled)"
           )
         ]
       )}
    end
  end
end
