defmodule SecantService.SecNodes.SecNode do
  use Ash.Resource,
    domain: SecantService.SecNodes,
    data_layer: AshPostgres.DataLayer,
    primary_read_warning?: false,
    extensions: [AshOban, AshStateMachine]

  alias SecantService.Util

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
      trigger :sync_node_states do
        scheduler_cron "0 * * * *"
        action :sync_node_state
        where expr(state == :active)
        read_action :read_for_state_transition
        worker_module_name SecantService.SecNodes.SecNode.AshOban.Worker.SyncNodeStates
        scheduler_module_name SecantService.SecNodes.SecNode.AshOban.Scheduler.SyncNodeStates
      end

      trigger :recalculate_storage_on_archive do
        scheduler_cron "0 * * * *"
        action :recalculate_storage
        read_action :read_for_storage_recalc
        where expr(state == :processed)

        worker_module_name SecantService.SecNodes.SecNode.AshOban.Worker.RecalculateStorageTransition

        scheduler_module_name SecantService.SecNodes.SecNode.AshOban.Scheduler.RecalculateStorageTransition
      end

      trigger :recalculate_storage_active do
        scheduler_cron "0 * * * *"
        action :recalculate_storage
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

    transitions do
      transition :sync_node_state, from: :active, to: :processed
      transition :archive, from: :active, to: :processed
      transition :recalculate_storage, from: :processed, to: :archived
      transition :trash, from: [:archived, :processed], to: :trashed
      transition :restore, from: :trashed, to: :archived
    end
  end

  code_interface do
    define :node_only, action: :node_only
    define :toggle_favourite, action: :toggle_favourite
    define :archive, action: :archive
    define :trash, action: :trash
    define :restore, action: :restore
    define :recalculate_storage, action: :recalculate_storage
    define :purge_all_trashed, action: :purge_all_trashed
  end

  actions do
    defaults [:destroy]

    read :node_only do
      prepare build(
                sort: [{:inserted_at, :desc}],
                load: [
                  :node_id,
                  :values_pubsub_topic,
                  :processed_values_pubsub_topic,
                  :error_pubsub_topic,
                  :node_id_str,
                  :display_description,
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

    read :read do
      primary? true

      prepare build(
                load: [
                  :node_id,
                  :values_pubsub_topic,
                  :processed_values_pubsub_topic,
                  :error_pubsub_topic,
                  :node_id_str,
                  :display_description,
                  :display_equipment_id,
                  modules: [:parameters, :commands]
                ]
              )
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

    read :read_for_state_transition do
      pagination keyset?: true, required?: false

      prepare build(
                load: [
                  :should_cleanup,
                  :should_purge
                ]
              )
    end

    # Read action for storage recalculation trigger with keyset pagination
    read :read_for_storage_recalc do
      pagination keyset?: true, required?: false

      prepare build(load: [])
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

    # Check if single UUID exists
    read :exists_by_uuid do
      argument :uuid, :uuid do
        allow_nil? false
      end

      filter expr(uuid == ^arg(:uuid))

      prepare build(select: [:uuid], load: [])

      get? true
    end

    # Check which UUIDs exist (for batch checking)
    read :exists_by_uuids do
      argument :uuids, {:array, :uuid} do
        allow_nil? false
      end

      filter expr(uuid in ^arg(:uuids))

      prepare build(select: [:uuid], load: [])
    end

    create :create do
      accept [
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

      argument :modules, {:array, :map}

      change manage_relationship(:modules, type: :create)
    end

    create :upsert do
      accept [
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
      require_atomic? false

      change fn changeset, _context ->
        current = Ash.Changeset.get_attribute(changeset, :favourite)
        Ash.Changeset.change_attribute(changeset, :favourite, !current)
      end
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

    update :sync_node_state do
      accept []
      require_atomic? false

      change SecantService.SecNodes.Changes.SyncNodeState
    end

    update :recalculate_storage do
      accept []
      require_atomic? false

      change SecantService.SecNodes.Changes.RecalculateSecNodeStorage
    end

    action :purge_all_trashed, :map do
      run fn _input, _context ->
        trashed_nodes =
          __MODULE__
          |> Ash.Query.filter_input(%{state: %{eq: :trashed}})
          |> Ash.read!()

        {success, failure} =
          Enum.reduce(trashed_nodes, {0, 0}, fn node, {s, f} ->
            case Ash.destroy(node) do
              :ok -> {s + 1, f}
              {:error, _} -> {s, f + 1}
            end
          end)

        {:ok, %{success: success, failure: failure}}
      end
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
    calculate :values_pubsub_topic,
              :string,
              expr(
                "value_update:" <> ^ref(:host) <> ":" <> fragment("CAST(? AS TEXT)", ^ref(:port))
              )

    calculate :processed_values_pubsub_topic,
              :string,
              expr(
                "value_update:processed:" <>
                  ^ref(:host) <> ":" <> fragment("CAST(? AS TEXT)", ^ref(:port))
              )

    calculate :error_pubsub_topic,
              :string,
              expr(
                "error_update:" <> ^ref(:host) <> ":" <> fragment("CAST(? AS TEXT)", ^ref(:port))
              )

    calculate :node_id_str,
              :string,
              expr(^ref(:host) <> ":" <> fragment("CAST(? AS TEXT)", ^ref(:port)))

    calculate :node_id, :term, fn records, _context ->
      Enum.map(records, fn record ->
        {String.to_charlist(record.host), record.port}
      end)
    end

    calculate :display_description, :string, fn records, _context ->
      Enum.map(records, fn record ->
        record.description
        |> String.split("\n")
        |> Enum.map(&Phoenix.HTML.html_escape/1)
        |> Enum.intersperse(Phoenix.HTML.raw("<br>"))
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
