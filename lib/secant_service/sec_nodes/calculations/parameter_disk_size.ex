defmodule SecantService.SecNodes.Calculations.ParameterDiskSize do
  @moduledoc """
  Calculation to compute the disk size used by a parameter's data from its
  active value table.

  Each parameter stores values in exactly one `parameter_values_*` table,
  derived from its `datainfo` type.

  Uses PostgreSQL row-size aggregation for rows that belong to the parameter.
  """

  use Ash.Resource.Calculation
  require Logger

  alias SecantService.SecNodes.ParameterValue

  @table_by_storage_type %{
    int: "parameter_values_int",
    double: "parameter_values_double",
    bool: "parameter_values_bool",
    string: "parameter_values_string",
    array_int: "parameter_values_array_int",
    array_double: "parameter_values_array_double",
    array_bool: "parameter_values_array_bool",
    array_string: "parameter_values_array_string",
    json: "parameter_values_json"
  }

  @impl true
  def load(_query, _opts, _context) do
    [:datainfo]
  end

  @impl true
  def calculate(parameters, _opts, _context) do
    repo = SecantService.Repo

    Enum.map(parameters, fn parameter ->
      table_name =
        parameter
        |> ParameterValue.get_storage_type()
        |> then(&Map.fetch!(@table_by_storage_type, &1))

      case calculate_disk_size_safe(parameter.id, table_name, repo) do
        {:ok, size} ->
          size

        {:error, reason} ->
          Logger.warning(
            "Failed to calculate disk size for parameter #{parameter.id}: #{inspect(reason)}"
          )

          0
      end
    end)
  end

  defp calculate_disk_size_safe(parameter_id, table_name, repo) do
    try do
      size = calculate_disk_size(parameter_id, table_name, repo)
      {:ok, size}
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end

  defp calculate_disk_size(parameter_id, table_name, repo) do
    query =
      "SELECT COALESCE(SUM(pg_column_size(t)), 0)::bigint FROM #{table_name} t WHERE t.parameter_id = $1"

    case Ecto.Adapters.SQL.query(repo, query, [parameter_id]) do
      {:ok, result} ->
        result.rows |> List.first() |> List.first() || 0

      {:error, _} ->
        0
    end
  end
end
