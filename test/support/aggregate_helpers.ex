defmodule SecantService.AggregateHelpers do
  @moduledoc """
  Helpers for testing the continuous aggregates over `readings`.

  `refresh_continuous_aggregate` cannot run inside a transaction, so these
  tests can't use the sandbox: `unboxed/1` runs a block on a real
  connection, and what it writes stays in the test database. Every SEC node
  a test creates through `parameter!/1` is deleted again in `on_exit`, and
  the views are refreshed once more so they hold none of its buckets.

  The views' refresh policies also run on the test database.
  `setup_aggregates/1`, as a `setup_all` callback, pauses them for the test
  module, so only the tests' own refreshes change the views. It also removes
  SEC nodes a killed earlier run left behind, so only one run of these tests
  may use a database at a time.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias SecantService.Repo
  alias SecantService.SecNodes
  alias SecantService.SecNodes.Reading.AggregateViews
  alias SecantService.SecNodes.Reading.Storage

  @doc "Runs `fun` on a connection outside the sandbox."
  def unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  @doc """
  `setup_all` callback: deletes SEC nodes left by an earlier run that was
  killed before its `on_exit`, and pauses the aggregates' policy jobs until
  the test module is done.
  """
  def setup_aggregates(_context) do
    jobs =
      unboxed(fn ->
        Repo.query!("DELETE FROM sec_nodes WHERE equipment_id LIKE 'aggregates\\_%'")
        Enum.each(AggregateViews.views(), &refresh!/1)

        %{rows: rows} =
          Repo.query!("""
          SELECT j.job_id FROM timescaledb_information.jobs j
          JOIN timescaledb_information.continuous_aggregates c
            ON c.view_schema = j.hypertable_schema AND c.view_name = j.hypertable_name
          WHERE j.scheduled
          """)

        jobs = List.flatten(rows)
        Enum.each(jobs, &Repo.query!("SELECT (alter_job($1, scheduled => false)).job_id", [&1]))
        jobs
      end)

    on_exit(fn ->
      unboxed(fn ->
        Enum.each(jobs, &Repo.query!("SELECT (alter_job($1, scheduled => true)).job_id", [&1]))
      end)
    end)

    :ok
  end

  @doc """
  A parameter with `datainfo` on a new SEC node, deleted with its readings
  in `on_exit`. Call it inside `unboxed/1`.
  """
  def parameter!(datainfo) do
    {node, parameter} =
      SecantService.Generators.node_with_parameter(
        node: [equipment_id: "aggregates_#{System.unique_integer([:positive])}"],
        datainfo: datainfo
      )

    on_exit(fn ->
      unboxed(fn ->
        Repo.query!("DELETE FROM sec_nodes WHERE uuid = $1", [Ecto.UUID.dump!(node.uuid)])
        Enum.each(AggregateViews.views(), &refresh!/1)
      end)
    end)

    parameter
  end

  @doc "Inserts `{value, %DateTime{}}` readings the way the app stores them."
  def insert!(parameter, readings) do
    rows = Enum.map(readings, fn {value, at} -> Storage.to_row(value, parameter, at, %{}) end)
    %Ash.BulkResult{status: :success} = SecNodes.insert_readings(rows)
    :ok
  end

  @doc """
  Inserts one reading with SQL, for values the storage helper doesn't
  produce, such as NaN: `insert_sql!(parameter, "value_float", "'NaN'::float8", at)`.
  `column` and `sql_value` are SQL, so pass only literals from the test.
  """
  def insert_sql!(parameter, column, sql_value, %DateTime{} = at) do
    Repo.query!(
      ~s|INSERT INTO readings (parameter_id, "timestamp", #{column}, qualifiers) | <>
        "VALUES ($1, $2, #{sql_value}, '{}')",
      [parameter.id, DateTime.to_naive(at)]
    )

    :ok
  end

  @doc """
  Refreshes a continuous aggregate, over its whole range or over
  `[from, to)` (`DateTime`s, aligned to its buckets).
  """
  def refresh!(view, from \\ nil, to \\ nil) when is_binary(view) do
    Repo.query!(
      "CALL refresh_continuous_aggregate($1::text::regclass, $2::timestamp, $3::timestamp)",
      [view, from && DateTime.to_naive(from), to && DateTime.to_naive(to)]
    )

    :ok
  end

  @doc "A view's rows for a parameter, as maps, ordered by its group key."
  def rows(view, parameter) do
    %{columns: columns, rows: rows} =
      Repo.query!("SELECT * FROM #{view} WHERE parameter_id = $1 ORDER BY 1, 2, 3, 4", [
        parameter.id
      ])

    Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
  end
end
