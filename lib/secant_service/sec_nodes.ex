defmodule SecantService.SecNodes do
  @moduledoc """
  Domain for managing SECoP nodes and their metadata.

  This module is the interface to the data: the web layer and the node
  processes call these functions rather than `Ash.*` directly.
  """

  use Ash.Domain,
    otp_app: :secant_service

  import Ecto.Query, only: [from: 2]
  require Ash.Query

  alias SecantService.SecNodes.{Reading, SecNode}

  resources do
    resource SecantService.SecNodes.Command

    resource SecantService.SecNodes.Module do
      define :get_module,
        action: :read,
        get_by: [:id],
        default_options: [load: [sec_node: [:node_id]]]
    end

    resource SecantService.SecNodes.Reading do
      # A parameter's readings, oldest first unless `order: :desc`. Readings
      # are many and can be large arrays: select the columns you need
      # (`query: [select: ...]`), and don't load relationships on them.
      define :readings, action: :for_parameter, args: [:parameter_id]

      # The newest reading (at or before `end_timestamp`), or nil
      define :latest_reading,
        action: :latest_for_parameter,
        args: [:parameter_id],
        get?: true,
        not_found_error?: false
    end

    resource SecantService.SecNodes.RecordingSpan do
      # writes a span whole, by id; see SecantService.RecordingTracker
      define :record_span, action: :record
      define :open_span, action: :open_for_session, args: [:sec_node_id], not_found_error?: false
    end

    resource SecantService.SecNodes.Parameter do
      define :get_parameter,
        action: :read,
        get_by: [:id],
        default_options: [load: [module: [sec_node: [:node_id]]]]

      define :recalculate_parameter_storage, action: :recalculate_storage

      define :parameters_of_node, action: :by_node_uuid, args: [:node_uuid]
      define :history_window, args: [:parameter_id, :from_ms, :to_ms]
      define :history_resolution, args: [:parameter_id, :from_ms, :to_ms]
    end

    resource SecantService.SecNodes.SecNode do
      # a session with everything it described, as the node services and
      # the node pages use it
      define :get_sec_node,
        action: :read,
        get_by: [:uuid],
        default_options: [load: [:node_id, modules: [:parameters, :commands]]]

      define :upsert_sec_node, action: :upsert
      define :active_sec_nodes, action: :active
      define :ended_sec_nodes_among, action: :ended_among, args: [:uuids]
      define :archive_sec_node, action: :archive
      define :reactivate_sec_node, action: :reactivate
      define :trash_sec_node, action: :trash
      define :restore_sec_node, action: :restore
      define :toggle_sec_node_favourite, action: :toggle_favourite
      define :purge_trashed_sec_nodes, action: :purge_all_trashed
    end
  end

  @doc """
  One page of the data browser: nodes of a tab (`:all`, `:active`,
  `:archived`, `:trashed`, `:favourite`), sorted, filtered and paginated by
  the AshPagify `params`.
  """
  def browse_sec_nodes(state_filter, params, opts \\ []) do
    AshPagify.validate_and_run(SecNode, params, [action: :node_only] ++ opts, state_filter)
  end

  @doc """
  One page of a parameter's stored readings for the history table, sorted
  and paginated by the AshPagify `params`.
  """
  def browse_readings(parameter, params, opts \\ []) do
    AshPagify.validate_and_run(Reading, params, [action: :for_parameter] ++ opts, %{
      parameter_id: parameter.id
    })
  end

  @doc """
  What this server holds, for the landing page: sessions recording now, the
  modules of those sessions, and all sessions not in the trash.
  """
  def overview_counts do
    %{
      recording: SecNode |> Ash.Query.for_read(:active) |> Ash.count!(),
      modules:
        SecantService.SecNodes.Module
        |> Ash.Query.filter(sec_node.state == :active)
        |> Ash.count!(),
      sessions: SecNode |> Ash.Query.filter(state != :trashed) |> Ash.count!()
    }
  end

  @doc "Schedule the cleanup trigger now (old sessions move to the trash in the background)."
  def schedule_cleanup, do: AshOban.schedule(SecNode, :cleanup_old_nodes)

  @doc """
  The newest stored reading of each of the given parameters, as
  `%{parameter_id => reading}`; ties on the timestamp go to the last one
  stored.

  One query, a `LIMIT 1` per parameter (lateral join), so Postgres walks the
  `(parameter_id, timestamp)` index backwards and TimescaleDB decompresses
  only that parameter's segment, however long the history is. Plain Ecto on
  the resource's schema, because Ash queries can't express a lateral join.
  """
  def latest_readings([]), do: %{}

  def latest_readings(parameter_ids) do
    newest =
      from(r in Reading,
        where: r.parameter_id == parent_as(:param).id,
        order_by: [desc: r.timestamp, desc: r.id],
        limit: 1
      )

    from(p in fragment("SELECT unnest(?::bigint[]) AS id", ^parameter_ids),
      as: :param,
      inner_lateral_join: r in subquery(newest),
      on: true,
      select: r
    )
    |> SecantService.Repo.all()
    |> Map.new(&{&1.parameter_id, &1})
  end

  @doc """
  Inserts readings (rows from `Reading.Storage.to_row/4`) in one statement.
  Returns the `Ash.BulkResult`.

  Authorization and notifications are off: this is the node services
  recording what the node reported, and readings have no notifiers. One
  batch per call: about 20% less time per row than the defaults.
  """
  def insert_readings(rows) do
    Ash.bulk_create(rows, Reading, :create,
      return_errors?: true,
      stop_on_error?: false,
      return_records?: false,
      authorize?: false,
      notify?: false,
      # all or nothing per call: a write killed midway leaves no rows behind,
      # so NodeDBWriter can send the rows again
      transaction: :batch,
      # Kernel. because the domain defines its own max/…
      batch_size: Kernel.max(length(rows), 1)
    )
  end
end
