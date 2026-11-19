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

  code_interface do
    define :history_window, args: [:parameter_id, :from_ms, :to_ms]
    define :history_resolution, args: [:parameter_id, :from_ms, :to_ms]
  end

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

      change SecantService.SecNodes.Changes.RecalculateParameterStorage
    end

    read :by_node_uuid do
      argument :node_uuid, :uuid do
        allow_nil? false
      end

      prepare build(load: [:module])

      filter expr(module.sec_node_id == ^arg(:node_uuid))
    end

    read :get_with_context do
      argument :id, :integer do
        allow_nil? false
      end

      filter expr(id == ^arg(:id))

      prepare build(load: [module: [sec_node: [:node_id]]])
    end

    # Readings for the historical plots, thinned out in the database when the
    # window holds more than a chart can show. See `SecantService.PlotDB.History`.
    action :history_window, :map do
      description "Readings of a numeric parameter in a time window, thinned out if there are many."

      argument :parameter_id, :integer, allow_nil?: false
      # Unix milliseconds, inclusive; nil = from the first / to the last reading
      argument :from_ms, :integer
      argument :to_ms, :integer
      # a window with at most this many readings is returned in full
      argument :max_raw, :integer, constraints: [min: 1]
      # otherwise it is split into at most this many time buckets
      argument :max_buckets, :integer, constraints: [min: 1]

      run SecantService.SecNodes.Actions.HistoryWindow
    end

    action :history_resolution, :map do
      description "How :history_window would answer (thinned out or not, bucket width), without loading the readings."

      argument :parameter_id, :integer, allow_nil?: false
      argument :from_ms, :integer
      argument :to_ms, :integer
      argument :max_raw, :integer, constraints: [min: 1]
      argument :max_buckets, :integer, constraints: [min: 1]

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

    has_many :parameter_values_array_bools, SecantService.SecNodes.ParameterValueArrayBool do
      public? true
    end

    has_many :parameter_values_array_doubles,
             SecantService.SecNodes.ParameterValueArrayDouble do
      public? true
    end

    has_many :parameter_values_array_ints, SecantService.SecNodes.ParameterValueArrayInt do
      public? true
    end

    has_many :parameter_values_array_strings,
             SecantService.SecNodes.ParameterValueArrayString do
      public? true
    end

    has_many :parameter_values_bools, SecantService.SecNodes.ParameterValueBool do
      public? true
    end

    has_many :parameter_values_doubles, SecantService.SecNodes.ParameterValueDouble do
      public? true
    end

    has_many :parameter_values_ints, SecantService.SecNodes.ParameterValueInt do
      public? true
    end

    has_many :parameter_values_jsons, SecantService.SecNodes.ParameterValueJson do
      public? true
    end

    has_many :parameter_values_strings, SecantService.SecNodes.ParameterValueString do
      public? true
    end
  end

  calculations do
    calculate :calculated_datapoint_count,
              :integer,
              SecantService.SecNodes.Calculations.ParameterDatapointCount

    calculate :calculated_disk_size_bytes,
              :integer,
              SecantService.SecNodes.Calculations.ParameterDiskSize
  end

  aggregates do
    count :parameter_values_array_bools_count, :parameter_values_array_bools
    count :parameter_values_array_doubles_count, :parameter_values_array_doubles
    count :parameter_values_array_ints_count, :parameter_values_array_ints
    count :parameter_values_array_strings_count, :parameter_values_array_strings
    count :parameter_values_bools_count, :parameter_values_bools
    count :parameter_values_doubles_count, :parameter_values_doubles
    count :parameter_values_ints_count, :parameter_values_ints
    count :parameter_values_jsons_count, :parameter_values_jsons
    count :parameter_values_strings_count, :parameter_values_strings
  end

  identities do
    identity :module_id_name, [:module_id, :name]
  end
end
