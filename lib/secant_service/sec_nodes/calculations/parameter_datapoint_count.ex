defmodule SecantService.SecNodes.Calculations.ParameterDatapointCount do
  @moduledoc """
  Calculation to compute datapoint count for parameters.

  Each parameter stores values in exactly one `parameter_values_*` table,
  derived from its `datainfo` type. This calculation counts rows only in that
  active table.
  """

  use Ash.Resource.Calculation

  alias SecantService.SecNodes.ParameterValue

  @aggregate_by_storage_type %{
    int: :parameter_values_ints_count,
    double: :parameter_values_doubles_count,
    bool: :parameter_values_bools_count,
    string: :parameter_values_strings_count,
    array_int: :parameter_values_array_ints_count,
    array_double: :parameter_values_array_doubles_count,
    array_bool: :parameter_values_array_bools_count,
    array_string: :parameter_values_array_strings_count,
    json: :parameter_values_jsons_count
  }

  @impl true
  def load(_query, _opts, _context) do
    [:datainfo] ++ Map.values(@aggregate_by_storage_type)
  end

  @impl true
  def calculate(parameters, _opts, _context) do
    Enum.map(parameters, fn parameter ->
      storage_type = ParameterValue.get_storage_type(parameter)
      aggregate_name = Map.fetch!(@aggregate_by_storage_type, storage_type)
      aggregate_value(parameter, aggregate_name)
    end)
  end

  defp aggregate_value(parameter, aggregate_name) do
    case Map.get(parameter, aggregate_name) do
      %Ash.NotLoaded{} -> 0
      nil -> 0
      value -> value
    end
  end
end
