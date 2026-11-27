defmodule SecantService.SecNodes.Parameter do
  use Ash.Resource,
    domain: SecantService.SecNodes,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "parameters"
    repo SecantService.Repo

    references do
      reference :module do
        on_delete :delete
      end
    end

    identity_index_names module_id_name: "parameters_module_id_name_index"
  end

  # the times a history window may span: years 0 to 9999, what a DateTime
  # holds (a node can stamp readings before 1970)
  @min_unix_ms -62_167_219_200_000
  @max_unix_ms 253_402_300_799_999

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :name,
        :datainfo,
        :readonly,
        :description,
        :group,
        :visibility,
        :meaning,
        :checkable,
        :custom_properties,
        :module_id
      ]

      upsert? true
      upsert_identity :module_id_name

      upsert_fields [
        :datainfo,
        :readonly,
        :description,
        :group,
        :visibility,
        :meaning,
        :checkable,
        :custom_properties
      ]
    end

    update :recalculate_storage do
      accept []
      require_atomic? false
      # the counts read the value hypertables; a failing query must not
      # abort a transaction (the change logs it and keeps the old counts)
      transaction? false

      change SecantService.SecNodes.Changes.RecalculateParameterStorage
    end

    read :by_node_uuid do
      argument :node_uuid, :uuid do
        allow_nil? false
      end

      prepare build(load: [:module])

      filter expr(module.sec_node_id == ^arg(:node_uuid))
    end

    # Readings for the historical plots, thinned out in the database when the
    # window holds more than a chart can show. See `SecantService.PlotDB.History`.
    action :history_window, :map do
      description "Readings of a plotted parameter (number, enum, numeric array or struct) in a time window, thinned out if there are many."

      argument :parameter_id, :integer, allow_nil?: false
      # Unix milliseconds, inclusive; nil = from the first / to the last reading
      argument :from_ms, :integer, constraints: [min: @min_unix_ms, max: @max_unix_ms]
      argument :to_ms, :integer, constraints: [min: @min_unix_ms, max: @max_unix_ms]
      # a window with at most this many readings is returned in full
      argument :max_raw, :integer, constraints: [min: 1, max: 50_000]
      # otherwise it is split into at most this many time buckets
      argument :max_buckets, :integer, constraints: [min: 1, max: 5_000]
      # read whole buckets of a minute or more from the aggregates, as a
      # min/mean/max envelope (see SecantService.PlotDB.History)
      argument :envelope, :boolean, default: false

      run SecantService.SecNodes.Actions.HistoryWindow
    end

    action :history_resolution, :map do
      description "How :history_window would answer (thinned out or not, bucket width), without loading the readings."

      argument :parameter_id, :integer, allow_nil?: false
      argument :from_ms, :integer, constraints: [min: @min_unix_ms, max: @max_unix_ms]
      argument :to_ms, :integer, constraints: [min: @min_unix_ms, max: @max_unix_ms]
      argument :max_raw, :integer, constraints: [min: 1, max: 50_000]
      argument :max_buckets, :integer, constraints: [min: 1, max: 5_000]

      run SecantService.SecNodes.Actions.HistoryWindow
    end
  end

  attributes do
    attribute :id, :integer do
      primary_key? true
      allow_nil? false
      generated? true
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :datainfo, :map do
      public? true
    end

    attribute :readonly, :boolean do
      generated? true
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :group, :string do
      public? true
    end

    attribute :visibility, :string do
      public? true
    end

    attribute :meaning, :map do
      public? true
    end

    attribute :checkable, :boolean do
      public? true
    end

    attribute :custom_properties, :map do
      public? true
    end

    attribute :datapoint_count, :integer do
      default 0
      allow_nil? false
      public? true
    end

    attribute :disk_size_bytes, :integer do
      default 0
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :module, SecantService.SecNodes.Module do
      allow_nil? false
      attribute_type :integer
      public? true
    end

    has_many :readings, SecantService.SecNodes.Reading do
      public? true
    end
  end

  calculations do
    calculate :calculated_disk_size_bytes,
              :integer,
              SecantService.SecNodes.Calculations.ParameterDiskSize

    # when the node's session began, where its historical plots start; one
    # joined query instead of loading the module and the node
    calculate :session_started_at, :utc_datetime_usec, expr(module.sec_node.inserted_at)
  end

  aggregates do
    count :calculated_datapoint_count, :readings
  end

  identities do
    identity :module_id_name, [:module_id, :name]
  end
end
