defmodule SecantService.Repo.Migrations.ConvertParameterValuesToHypertables do
  @moduledoc """
  Turns the `parameter_values_*` tables into TimescaleDB hypertables with
  columnar compression (the "columnstore").

  Hand-written: Ash's migration generator does not know about hypertables, so
  the resource snapshots don't describe any of this. Keep that in mind when a
  later `mix ash.codegen` touches these tables (changing a column's type on a
  compressed hypertable is not supported, for example).

  - Chunks are one day wide, so a day's data can be compressed as a unit.
  - Compressed batches are segmented by `parameter_id`: each parameter's
    readings are stored together, which is what plot queries filter on and what
    makes long runs of repeated values compress to almost nothing. Deleting a
    node cascades to its parameters' values with a `parameter_id` filter, which
    matches the segments too.
  - `id` is in the ordering because it is part of the primary key, and
    Timescale needs unique-key columns there to check uniqueness in compressed
    data.
  - Chunks are compressed once they are older than a day. Inserting into or
    deleting from compressed chunks still works.

  `create_default_indexes => false` because the tables already have indexes on
  `timestamp` and `(parameter_id, timestamp)`. Existing rows are moved into
  chunks (`migrate_data`), which can take a while on a large database.

  Irreversible: a hypertable can't be turned back into a plain table in place.
  """

  use Ecto.Migration

  @tables ~w(
    parameter_values_int
    parameter_values_double
    parameter_values_bool
    parameter_values_string
    parameter_values_array_int
    parameter_values_array_double
    parameter_values_array_bool
    parameter_values_array_string
    parameter_values_json
  )

  @chunk_interval "1 day"
  @compress_after "1 day"

  def up do
    for table <- @tables do
      execute("""
      SELECT create_hypertable(
        '#{table}',
        by_range('timestamp', INTERVAL '#{@chunk_interval}'),
        create_default_indexes => false,
        migrate_data => true
      )
      """)

      execute("""
      ALTER TABLE #{table} SET (
        timescaledb.enable_columnstore = true,
        timescaledb.segmentby = 'parameter_id',
        timescaledb.orderby = 'timestamp DESC, id DESC'
      )
      """)

      execute("CALL add_columnstore_policy('#{table}', after => INTERVAL '#{@compress_after}')")
    end
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "ConvertParameterValuesToHypertables is irreversible: hypertables can't be " <>
          "converted back to plain tables in place. Restore from a backup instead."
  end
end
