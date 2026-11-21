defmodule SecantService.SecNodes do
  @moduledoc """
  Domain for managing SECoP nodes and their metadata.

  This module is the interface to the data: the web layer and the node
  processes call these functions rather than `Ash.*` directly.
  """

  use Ash.Domain,
    otp_app: :secant_service

  alias SecantService.SecNodes.{ParameterValue, SecNode}

  resources do
    resource SecantService.SecNodes.Command

    resource SecantService.SecNodes.Module do
      define :get_module,
        action: :read,
        get_by: [:id],
        default_options: [load: [sec_node: [:node_id]]]
    end

    resource SecantService.SecNodes.ParameterValueArrayBool
    resource SecantService.SecNodes.ParameterValueArrayDouble
    resource SecantService.SecNodes.ParameterValueArrayInt
    resource SecantService.SecNodes.ParameterValueArrayString
    resource SecantService.SecNodes.ParameterValueBool
    resource SecantService.SecNodes.ParameterValueDouble
    resource SecantService.SecNodes.ParameterValueInt
    resource SecantService.SecNodes.ParameterValueJson
    resource SecantService.SecNodes.ParameterValueString

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
  of the value resources' `:for_parameter` read (e.g. a time window).
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

    parameter
    |> ParameterValue.get_resource_module()
    |> Ash.Query.for_read(:for_parameter, Map.put(args, :parameter_id, parameter.id))
    |> then(&if(opts[:select], do: Ash.Query.select(&1, opts[:select]), else: &1))
  end

  @doc "Schedule the cleanup trigger now (old sessions move to the trash in the background)."
  def schedule_cleanup, do: AshOban.schedule(SecNode, :cleanup_old_nodes)

  @doc """
  Inserts readings of one storage type (see `ParameterValue.get_resource_module/1`)
  in one statement. Rows with a nil value are skipped. Returns the
  `Ash.BulkResult`.

  Authorization and notifications are off: this is the node services
  recording what the node reported, and the value resources have no
  notifiers. One batch per call: about 20% less time per row than the
  defaults.
  """
  def insert_readings(storage_type, rows) do
    rows = Enum.reject(rows, &is_nil(&1.value))

    Ash.bulk_create(rows, ParameterValue.get_resource_module(storage_type), :bulk_create,
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
