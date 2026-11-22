defmodule SecantService.SecNodes.Calculations.ParameterDiskSize do
  @moduledoc """
  Bytes the readings of each parameter take, summed per row with
  `pg_column_size`. One query for all parameters being loaded.

  This is the size of the rows as Postgres hands them out, so for compressed
  chunks it overstates what is on disk; it is meant for comparing parameters,
  not for capacity planning.
  """

  use Ash.Resource.Calculation

  @query """
  SELECT r.parameter_id, COALESCE(SUM(pg_column_size(r)), 0)::bigint
  FROM readings r
  WHERE r.parameter_id = ANY($1)
  GROUP BY r.parameter_id
  """

  @impl true
  def load(_query, _opts, _context), do: []

  @impl true
  def calculate(parameters, _opts, _context) do
    ids = Enum.map(parameters, & &1.id)

    # An error fails the load: a parameter whose size could not be counted
    # must not look empty (RecalculateParameterStorage keeps the old count).
    with {:ok, %{rows: rows}} <- Ecto.Adapters.SQL.query(SecantService.Repo, @query, [ids]) do
      sizes = Map.new(rows, fn [id, size] -> {id, size} end)
      {:ok, Enum.map(parameters, &Map.get(sizes, &1.id, 0))}
    end
  end
end
