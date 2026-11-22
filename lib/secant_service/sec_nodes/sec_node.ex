defmodule SecantService.SecNodes.SecNode do
  use Ash.Resource,
    domain: SecantService.SecNodes,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban, AshStateMachine]

  alias SecantService.Util

  # what a stored description sets; shared by :create and :upsert
  @node_fields [
    :uuid,
    :equipment_id,
    :host,
    :port,
    :description,
    :firmware,
    :implementor,
    :timeout,
    :describe_message,
    :describe_message_raw,
    :custom_properties,
    :check_result,
    :ophyd_class
  ]

  @ash_pagify_options %{
    default_limit: 10
    # scopes
  }
  def ash_pagify_options, do: @ash_pagify_options

  postgres do
    table "sec_nodes"
    repo SecantService.Repo

    custom_indexes do
      index [:equipment_id] do
        name "equipment_id_index"
      end
    end
  end

  oban do
    triggers do
      trigger :recalculate_storage_on_archive do
        scheduler_cron "0 * * * *"
        action :finish_archiving
        read_action :read_for_storage_recalc
        where expr(state == :processed)

        worker_module_name SecantService.SecNodes.SecNode.AshOban.Worker.RecalculateStorageTransition

        scheduler_module_name SecantService.SecNodes.SecNode.AshOban.Scheduler.RecalculateStorageTransition
      end

      trigger :recalculate_storage_active do
        scheduler_cron "0 * * * *"
        action :refresh_storage
        where expr(state == :active)
        read_action :read_for_storage_recalc
        worker_module_name SecantService.SecNodes.SecNode.AshOban.Worker.RecalculateStorageHourly

        scheduler_module_name SecantService.SecNodes.SecNode.AshOban.Scheduler.RecalculateStorageHourly
      end

      trigger :cleanup_old_nodes do
        scheduler_cron "0 2 * * *"
        action :trash
        where expr(should_cleanup == true)
        read_action :read_for_cleanup
        worker_module_name SecantService.SecNodes.SecNode.AshOban.Worker.CleanupOldNodes
        scheduler_module_name SecantService.SecNodes.SecNode.AshOban.Scheduler.CleanupOldNodes
      end

      trigger :purge_trashed_nodes do
        scheduler_cron "0 3 * * *"
        action :destroy
        where expr(should_purge == true)
        read_action :read_trashed
        worker_module_name SecantService.SecNodes.SecNode.AshOban.Worker.PurgeTrashedNodes
        scheduler_module_name SecantService.SecNodes.SecNode.AshOban.Scheduler.PurgeTrashedNodes
      end
    end
  end

  state_machine do
    initial_states [:active]
    default_initial_state :active

    # Only SecantService.NodeManager moves a session out of :active (when
    # its services stop) or back into it (when the node still reports that
    # session's uuid, which it must keep recording).
    transitions do
      transition :archive, from: :active, to: :processed
      transition :reactivate, from: [:processed, :archived, :trashed], to: :active
      transition :finish_archiving, from: :processed, to: :archived
      transition :trash, from: [:archived, :processed], to: :trashed
      transition :restore, from: :trashed, to: :archived
    end
  end

  # The domain (`SecantService.SecNodes`) is the public interface. This one
  # exists only because AshPagify calls `SecNode.node_only(args, opts)`.
  code_interface do
    define :node_only, action: :node_only, args: [:state_filter]
  end

  actions do
    defaults [:read, :destroy]

    # Listing for the data browser, filtered by tab.
    read :node_only do
      argument :state_filter, :atom do
        allow_nil? false
        constraints one_of: [:all, :active, :archived, :trashed, :favourite]
        default :all
      end

      prepare SecantService.SecNodes.Preparations.FilterByTab

      prepare build(
                sort: [{:inserted_at, :desc}],
                load: [
                  :node_id,
                  :node_id_str,
                  :display_equipment_id,
                  :datapoint_count,
                  :disk_size_bytes
                ]
              )

      pagination offset?: true,
                 default_limit: @ash_pagify_options.default_limit,
                 countable: true,
                 required?: false
    end

    # The sessions marked as recording, for the NodeManager to compare with
    # the services that actually run
    read :active do
      filter expr(state == :active)
    end

    # The ended sessions among `uuids`, for the NodeManager to reactivate
    # those that are still live
    read :ended_among do
      argument :uuids, {:array, :uuid}, allow_nil?: false
      filter expr(uuid in ^arg(:uuids) and state != :active)
    end

    # Read action for cleanup trigger with keyset pagination
    read :read_for_cleanup do
      pagination keyset?: true, required?: false

      prepare build(
                load: [
                  :should_cleanup
                ]
              )
    end

    # Read action for storage recalculation trigger with keyset pagination
    read :read_for_storage_recalc do
      pagination keyset?: true, required?: false
    end

    # Read action for purge trigger with keyset pagination
    read :read_trashed do
      pagination keyset?: true, required?: false

      filter expr(state == :trashed)

      prepare build(
                load: [
                  :should_purge
                ]
              )
    end

    create :create do
      accept @node_fields

      argument :modules, {:array, :map}

      change manage_relationship(:modules, type: :create)
    end

    create :upsert do
      accept @node_fields

      argument :modules, {:array, :map}

      upsert? true
      upsert_identity :unique_uuid

      upsert_fields [
        :equipment_id,
        :host,
        :port,
        :description,
        :firmware,
        :implementor,
        :timeout,
        :describe_message,
        :describe_message_raw,
        :custom_properties,
        :check_result,
        :state,
        :ophyd_class
      ]

      change manage_relationship(:modules, type: :create)
    end

    update :toggle_favourite do
      accept []
      change atomic_update(:favourite, expr(not favourite))
    end

    update :archive do
      change run_oban_trigger(:recalculate_storage_on_archive)
      change transition_state(:processed)
    end

    update :trash do
      change transition_state(:trashed)
    end

    update :restore do
      change transition_state(:archived)
    end

    update :reactivate do
      change transition_state(:active)
    end

    # processed -> archived: the final storage count of a finished session
    update :finish_archiving do
      accept []
      require_atomic? false
      # recounting reads the value hypertables; no need to hold a transaction
      transaction? false

      change SecantService.SecNodes.Changes.RecalculateSecNodeStorage
      change transition_state(:archived)
      # The state is checked on the record as it was read, before the
      # recount. Reactivated meanwhile, the session must stay active.
      change filter(expr(state == :processed))
    end

    # Hourly storage count of a session that is still recording
    update :refresh_storage do
      accept []
      require_atomic? false
      transaction? false

      change SecantService.SecNodes.Changes.RecalculateSecNodeStorage
    end

    action :purge_all_trashed, :map do
      run SecantService.SecNodes.Actions.PurgeTrashed
    end
  end

  attributes do
    attribute :uuid, :uuid do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :equipment_id, :string do
      allow_nil? false
      public? true
    end

    attribute :host, :string do
      allow_nil? false
      public? true
    end

    attribute :port, :integer do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :firmware, :string do
      public? true
    end

    attribute :implementor, :string do
      public? true
    end

    attribute :timeout, :integer do
      public? true
    end

    attribute :describe_message, :map do
      public? true
    end

    attribute :describe_message_raw, :string do
      public? true
    end

    attribute :custom_properties, :map do
      public? true
    end

    attribute :check_result, :map do
      public? true
    end

    attribute :ophyd_class, :string do
      public? true
    end

    attribute :favourite, :boolean do
      default false
      allow_nil? false
      public? true
    end

    timestamps public?: true
  end

  relationships do
    has_many :modules, SecantService.SecNodes.Module do
      source_attribute :uuid
      public? true
    end
  end

  calculations do
    calculate :node_id_str,
              :string,
              expr(^ref(:host) <> ":" <> fragment("CAST(? AS TEXT)", ^ref(:port)))

    calculate :node_id, :term, fn records, _context ->
      Enum.map(records, fn record ->
        {String.to_charlist(record.host), record.port}
      end)
    end

    calculate :display_equipment_id, :string, fn records, _context ->
      Enum.map(records, fn record ->
        Util.display_name(record.equipment_id)
      end)
    end

    calculate :should_cleanup,
              :boolean,
              SecantService.SecNodes.Calculations.ShouldCleanup

    calculate :should_purge,
              :boolean,
              SecantService.SecNodes.Calculations.ShouldPurge
  end

  aggregates do
    sum :datapoint_count, [:modules, :parameters], :datapoint_count
    sum :disk_size_bytes, [:modules, :parameters], :disk_size_bytes
  end

  identities do
    identity :unique_uuid, [:uuid]
  end
end
