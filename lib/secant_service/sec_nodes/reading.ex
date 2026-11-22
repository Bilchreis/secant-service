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
      argument :limit, :integer

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

      prepare build(limit: arg(:limit)) do
        where present(:limit)
      end
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
