defmodule SecantService.SecNodes.Reading do
  @moduledoc """
  One value a SEC node reported for a parameter, as it was sent.

  All readings live in one TimescaleDB hypertable, `readings`. Each row sets
  exactly one `value_*` column, chosen from the parameter's datainfo by
  `SecantService.SecNodes.Reading.Storage`; the other columns are null, which
  compressed chunks store almost for free. Numeric arrays are typed columns:
  they decode several times faster than JSON and spectra take a third less
  space.

  The hypertable and its compression are custom statements below, so the
  migration generator and the snapshots know about them. They follow the
  pattern in ash_postgres#169, with the current columnstore API:

  - One-day chunks, compressed once they are a day old.
  - Compressed batches are segmented by `parameter_id`, so each parameter's
    readings are stored together; that is what plots filter on, and the
    `value_*` columns a parameter does not use compress to almost nothing.
  - `id` is in the ordering because it is part of the primary key, and
    TimescaleDB needs unique-key columns there to check uniqueness in
    compressed data.

  Changing `segmentby` or `orderby` later needs a hand-edited migration: the
  generator would run the old `down` first, and compression can't be turned
  off while compressed chunks exist. The policy statement regenerates
  cleanly.

  ## Aggregates

  Continuous aggregates keep per-bucket summaries of the readings that plots
  draw. Their SQL is in `SecantService.SecNodes.Reading.AggregateViews`, and
  `SecantService.PlotDB.Aggregates` reads them. Each view exists at a
  1-minute tier over `readings` and a 1-hour tier rolled up from it:

  - `reading_numbers_*`: `double`, `int` and `scaled` parameters and arrays
    of them, per element (`idx` 1.., a scalar is `idx` 1), plus the length of
    every aggregated array as `idx` 0. Stores min and max as
    `[value, time, id]` keys, first and last as `[time, id, value]` keys,
    and sum and count for the mean.
  - `reading_states_*`: `enum` and `bool` parameters and arrays of them, one
    row per state that occurs, with its first and last time and its count.
  - `reading_member_numbers_*` and `reading_member_states_*`: the same for
    the direct members of structs (keyed by name) and tuples (by position),
    unpacked by the SQL function `reading_member_values`.

  Times in the keys are epoch microseconds in float8, exact up to
  2106-02-07. Strings, nested members, whole structs and values kept in
  `value_json` because they did not fit their type are not aggregated.

  Policies refresh the 1-minute views every minute and the 1-hour views every
  15 minutes, over the whole range, oldest first, so late readings and
  deletes reach every bucket. A view's watermark (`materialized_until` in the
  reader) is only a high-water mark: buckets before it are not guaranteed to
  be current until the next refresh has covered them.

  A continuous aggregate's query can't be altered, and `CREATE OR REPLACE` on
  `reading_member_values` doesn't re-materialize buckets already built with
  it. Changing a view or the function therefore needs a hand-written
  migration that drops and recreates the views. The policies then backfill
  them. A manual `refresh_continuous_aggregate` runs in 10-bucket batches,
  newest first, unless its `options` say otherwise; batched like the policies
  (`%{buckets_per_batch: 360, refresh_newest_first: false}`), the bench's
  `reading_states_1m` refreshed in 1 s instead of 30 s.
  """
  use Ash.Resource,
    domain: SecantService.SecNodes,
    data_layer: AshPostgres.DataLayer

  @ash_pagify_options %{default_limit: 10}
  def ash_pagify_options, do: @ash_pagify_options

  @value_columns [
    :value_float,
    :value_int,
    :value_bool,
    :value_text,
    :value_float_array,
    :value_int_array,
    :value_bool_array,
    :value_text_array,
    :value_json
  ]

  @doc "The `value_*` columns; each reading sets one of them."
  def value_columns, do: @value_columns

  postgres do
    table "readings"
    repo SecantService.Repo

    references do
      reference :parameter do
        on_delete :delete
      end
    end

    custom_indexes do
      index [:parameter_id, :timestamp] do
        name "readings_parameter_id_timestamp_index"
      end
    end

    custom_statements do
      # Dropping the table drops the hypertable, so there is nothing to undo.
      statement :readings_hypertable do
        up """
        SELECT create_hypertable(
          'readings',
          by_range('timestamp', INTERVAL '1 day'),
          create_default_indexes => false
        )
        """

        down "SELECT 1"
      end

      statement :readings_columnstore do
        up """
        ALTER TABLE readings SET (
          timescaledb.enable_columnstore = true,
          timescaledb.segmentby = 'parameter_id',
          timescaledb.orderby = 'timestamp DESC, id DESC'
        )
        """

        down "ALTER TABLE readings SET (timescaledb.enable_columnstore = false)"
      end

      statement :readings_columnstore_policy do
        up "CALL add_columnstore_policy('readings', after => INTERVAL '1 day')"
        down "CALL remove_columnstore_policy('readings')"
      end

      # The continuous aggregates, in creation order (see AggregateViews).
      for aggregate <- SecantService.SecNodes.Reading.AggregateViews.statements() do
        statement aggregate.name do
          up aggregate.up
          down aggregate.down
        end
      end
    end
  end

  # The domain (`SecantService.SecNodes`) is the public interface. This one
  # exists only because AshPagify calls `Reading.for_parameter(args, opts)`
  # for the history table.
  code_interface do
    define :for_parameter, action: :for_parameter
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:parameter_id, :timestamp, :qualifiers | @value_columns]
    end

    read :for_parameter do
      pagination offset?: true,
                 default_limit: @ash_pagify_options.default_limit,
                 countable: true,
                 required?: false

      argument :parameter_id, :integer, allow_nil?: false
      argument :start_timestamp, :utc_datetime_usec
      argument :end_timestamp, :utc_datetime_usec

      argument :order, :atom do
        default :asc
        constraints one_of: [:asc, :desc]
      end

      filter expr(parameter_id == ^arg(:parameter_id))

      prepare build(filter: expr(timestamp >= ^arg(:start_timestamp))) do
        where present(:start_timestamp)
      end

      prepare build(filter: expr(timestamp <= ^arg(:end_timestamp))) do
        where present(:end_timestamp)
      end

      # id second: readings with the same timestamp keep the order they were
      # stored in, which also keeps offset pagination stable
      prepare build(sort: [{:timestamp, arg(:order)}, {:id, arg(:order)}])
    end

    # The newest reading of a parameter, optionally at or before
    # `end_timestamp`. The limit is part of the action: a `get?` interface
    # reads with `Ash.read_one`, which adds none, and without it the read
    # would decompress the parameter's whole history.
    read :latest_for_parameter do
      argument :parameter_id, :integer, allow_nil?: false
      argument :end_timestamp, :utc_datetime_usec

      filter expr(parameter_id == ^arg(:parameter_id))

      prepare build(filter: expr(timestamp <= ^arg(:end_timestamp))) do
        where present(:end_timestamp)
      end

      prepare build(sort: [timestamp: :desc, id: :desc], limit: 1)
    end
  end

  attributes do
    # Ash needs a primary key, and TimescaleDB needs the time column in every
    # unique index of a hypertable. The key deliberately does not make
    # (parameter_id, timestamp) unique: a node may send two different values
    # with the same timestamp, and both are kept. Exact repeats are skipped
    # by NodeDBWriter instead.
    attribute :id, :integer do
      primary_key? true
      allow_nil? false
      generated? true
      public? true
    end

    attribute :timestamp, :utc_datetime_usec do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :value_float, :float, public?: true
    attribute :value_int, :integer, public?: true
    attribute :value_bool, :boolean, public?: true
    # strings exactly as sent: empty strings and whitespace are kept
    attribute :value_text, :string, public?: true, constraints: [allow_empty?: true, trim?: false]
    attribute :value_float_array, {:array, :float}, public?: true
    attribute :value_int_array, {:array, :integer}, public?: true
    attribute :value_bool_array, {:array, :boolean}, public?: true

    attribute :value_text_array, {:array, :string},
      public?: true,
      constraints: [items: [allow_empty?: true, trim?: false]]

    attribute :value_json, :map, public?: true

    # The qualifiers the node sent, except "t" (that is `timestamp`).
    attribute :qualifiers, :map, public?: true
  end

  relationships do
    belongs_to :parameter, SecantService.SecNodes.Parameter do
      allow_nil? false
      attribute_type :integer
      public? true
    end
  end
end
