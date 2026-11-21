defmodule SecantService.SecNodes do
  @moduledoc """
  Domain for managing SECoP nodes and their metadata.

  This module is the interface to the data: the web layer and the node
  processes call these functions rather than `Ash.*` directly.
  """

  use Ash.Domain,
    otp_app: :secant_service

  import Ecto.Query, only: [from: 2]

  alias SecantService.SecNodes.{Reading, SecNode}

  resources do
    resource SecantService.SecNodes.Command

    resource SecantService.SecNodes.Module do
      define :get_module,
        action: :read,
        get_by: [:id],
        default_options: [load: [sec_node: [:node_id]]]
    end

    resource SecantService.SecNodes.Reading

    resource SecantService.SecNodes.Parameter do
      define :get_parameter,
        action: :read,
        get_by: [:id],
        default_options: [load: [module: [sec_node: [:node_id]]]]

      define :parameters_of_node, action: :by_node_uuid, args: [:node_uuid]
      define :history_window, args: [:parameter_id, :from_ms, :to_ms]
      define :history_resolution, args: [:parameter_id, :from_ms, :to_ms]
    end

    resource SecantService.SecNodes.SecNode do
      define :get_sec_node, action: :read, get_by: [:uuid]
      define :upsert_sec_node, action: :upsert
      define :archive_sec_node, action: :archive
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
  The stored readings of a parameter, oldest first. `args` are the arguments
  of `Reading`'s `:for_parameter` read (e.g. a time window).
  """
  def readings!(parameter, args \\ %{}, opts \\ []) do
    parameter |> readings_query(args, opts) |> Ash.read!()
  end

  @doc "Like `readings!/3`, returning `{:ok, readings}` or `{:error, error}`."
  def readings(parameter, args \\ %{}, opts \\ []) do
    parameter |> readings_query(args, opts) |> Ash.read()
  end

  @doc """
  The newest reading of a parameter (optionally before `args.end_timestamp`):
  `{:ok, reading}`, `{:ok, nil}` when there is none, or `{:error, error}`.
  """
  def latest_reading(parameter, args \\ %{}) do
    parameter
    |> readings_query(Map.merge(args, %{limit: 1, order: :desc}), [])
    |> Ash.read_first()
  end

  defp readings_query(parameter, args, opts) do
    opts = Keyword.validate!(opts, [:select])

    Reading
    |> Ash.Query.for_read(:for_parameter, Map.put(args, :parameter_id, parameter.id))
    |> then(&if(opts[:select], do: Ash.Query.select(&1, opts[:select]), else: &1))
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
      # Kernel. because the domain defines its own max/…
      batch_size: Kernel.max(length(rows), 1)
    )
  end
end
