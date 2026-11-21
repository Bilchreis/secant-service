defmodule SecantService.Repo.Migrations.CreateReadingsHypertable do
  @moduledoc """
  Turns `readings` into a TimescaleDB hypertable with columnar compression,
  with the same settings the nine `parameter_values_*` tables had (see
  `ConvertParameterValuesToHypertables`).

  Hand-written: Ash's migration generator does not know about hypertables.

  - One-day chunks, compressed once they are a day old.
  - Compressed batches are segmented by `parameter_id`, so each parameter's
    readings are stored together; that is what plots filter on, and the
    `value_*` columns a parameter does not use compress to almost nothing.
  - `id` is in the ordering because it is part of the primary key, and
    Timescale needs unique-key columns there to check uniqueness in
    compressed data.

  Irreversible: a hypertable can't be turned back into a plain table in place.
  """

  use Ecto.Migration

  def up do
    execute("""
    SELECT create_hypertable(
      'readings',
      by_range('timestamp', INTERVAL '1 day'),
      create_default_indexes => false
    )
    """)

    execute("""
    ALTER TABLE readings SET (
      timescaledb.enable_columnstore = true,
      timescaledb.segmentby = 'parameter_id',
      timescaledb.orderby = 'timestamp DESC, id DESC'
    )
    """)

    execute("CALL add_columnstore_policy('readings', after => INTERVAL '1 day')")
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "CreateReadingsHypertable is irreversible: a hypertable can't be converted " <>
          "back to a plain table in place. Restore from a backup instead."
  end
end
