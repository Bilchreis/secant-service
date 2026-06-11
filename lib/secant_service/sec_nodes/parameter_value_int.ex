defmodule SecantService.SecNodes.ParameterValueInt do
  use Ash.Resource,
    domain: SecantService.SecNodes,
    data_layer: AshPostgres.DataLayer

  alias SecantService.SecNodes.ParameterValue

  @ash_pagify_options ParameterValue.ash_pagify_options()
  def ash_pagify_options, do: @ash_pagify_options

  postgres do
    table "parameter_values_int"
    repo SecantService.Repo

    references do
      reference :parameter do
        on_delete :delete
      end
    end

    custom_indexes do
      index [:parameter_id, :timestamp] do
        name "parameter_values_int_parameter_id_timestamp_index"
      end

      index [:timestamp] do
        name "parameter_values_int_timestamp_index"
      end
    end
  end

  code_interface do
    define :for_parameter, action: :for_parameter
  end

  actions do
    defaults [:destroy]

    create :create do
      accept [:value, :parameter_id, :timestamp, :qualifiers]
    end

    create :bulk_create do
      accept [:value, :parameter_id, :timestamp, :qualifiers]
    end

    read :read do
      primary? true
    end

    read :for_parameter do
      pagination offset?: true,
                 default_limit: @ash_pagify_options.default_limit,
                 countable: true,
                 required?: false

      argument :parameter_id, :integer do
        allow_nil? false
      end

      argument :start_timestamp, :utc_datetime_usec
      argument :end_timestamp, :utc_datetime_usec
      argument :limit, :integer

      argument :order, :atom do
        default :asc
        constraints one_of: [:asc, :desc]
      end

      # Filter by parameter_id (always required)
      prepare build(filter: expr(parameter_id == ^arg(:parameter_id)))

      # Filter by start_timestamp if provided
      prepare build(filter: expr(timestamp >= ^arg(:start_timestamp))) do
        where present(:start_timestamp)
      end

      # Filter by end_timestamp if provided
      prepare build(filter: expr(timestamp <= ^arg(:end_timestamp))) do
        where present(:end_timestamp)
      end

      # Sort by timestamp with the order from argument
      prepare build(sort: [{:timestamp, arg(:order)}])

      # Apply limit if provided
      prepare build(limit: arg(:limit)) do
        where present(:limit)
      end
    end
  end

  attributes do
    attribute :id, :integer do
      primary_key? true
      allow_nil? false
      generated? true
      public? true
    end

    attribute :value, :integer do
      allow_nil? false
      public? true
    end

    attribute :timestamp, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :qualifiers, :map do
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :parameter, SecantService.SecNodes.Parameter do
      allow_nil? false
      attribute_type :integer
      public? true
    end
  end
end
