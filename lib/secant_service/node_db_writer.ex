defmodule SecantService.NodeDBWriter do
  @batch_interval 10_000
  @max_batch_size 1000

  @moduledoc """
  Records what a node sends: every value update becomes a `Reading`, written
  in batches (every #{div(@batch_interval, 1000)} s, or sooner at #{@max_batch_size} readings).

  The record is faithful: a value is stored every time it arrives with a new
  timestamp, even if it did not change, and two different values with the
  same timestamp are both stored. Only an exact repeat of the last reading of
  a parameter (same timestamp and same value) is skipped. Nodes resend their
  current values with the original timestamps when they are activated again,
  e.g. after a reconnect; those are repeats. The last stored reading of each
  parameter is loaded at start, so that also holds across restarts of the
  node services.

  Values already known when the writer starts (`NodeValues`) are written as
  well, unless they are not newer than what is stored: `NodeValues` keeps the
  timestamp of the last *change*, so after a restart of the writer alone it
  can hold an older reading of a value that has been stored since.
  """
  use GenServer
  require Logger

  alias SecantService.SecNodes
  alias SecantService.SecNodes.Reading.Storage

  @pubsub_name :secant_client_pubsub

  def start_link(node_db) do
    GenServer.start_link(__MODULE__, node_db,
      name: {:via, Registry, {Registry.NodeDBWriter, node_db.uuid}}
    )
  end

  @impl true
  def init(node_db) do
    # Trap exits so terminate/2 runs (and flushes the pending batch) when the
    # node services are shut down, e.g. on a description change.
    Process.flag(:trap_exit, true)
    Phoenix.PubSub.subscribe(@pubsub_name, node_db.values_pubsub_topic)

    parameters = build_parameter_cache(node_db.uuid)

    Logger.info(
      "Started DB writer for #{node_db.equipment_id} (#{node_db.uuid}), #{map_size(parameters)} parameters"
    )

    schedule_batch_flush()
    send(self(), :write_initial_values)

    {:ok,
     %{
       equipment_id: node_db.equipment_id,
       node_id: node_db.node_id,
       parameters: parameters,
       last: load_last_readings(parameters),
       # newest first
       batch: [],
       batch_size: 0
     }}
  end

  @impl true
  def handle_info({:value_update, module, parameter, [value, qualifiers]}, state) do
    {:noreply, state |> add(module, parameter, value, qualifiers, :live) |> maybe_flush()}
  end

  def handle_info(:flush_parameter_batch, state) do
    schedule_batch_flush()
    {:noreply, flush(state)}
  end

  # The node services start after the node was described; whatever the node
  # reported before that is in NodeValues. Written in this process so it lands
  # before later batches.
  def handle_info(:write_initial_values, state) do
    case SecantService.NodeValues.get_values(state.node_id) do
      {:ok, values} ->
        state =
          Enum.reduce(state.parameters, state, fn {{module, param}, _}, state ->
            case get_in(values, [module, param]) do
              %{data_report: [value, qualifiers]} ->
                add(state, module, param, value, qualifiers, :initial)

              _ ->
                state
            end
          end)

        Logger.info("Writing #{state.batch_size} initial values for #{state.equipment_id}")
        write(state.batch)
        {:noreply, %{state | batch: [], batch_size: 0}}

      {:error, reason} ->
        Logger.warning(
          "Could not get initial values for #{state.equipment_id}: #{inspect(reason)}"
        )

        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("NodeDBWriter received unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    # Synchronously, so the values are stored before the services are gone
    # (e.g. on a description change).
    write(state.batch)
    Logger.info("Stopping NodeDBWriter for #{state.equipment_id} (#{inspect(reason)})")
    :ok
  end

  # -- batching ----------------------------------------------------------------

  defp add(state, module, param, value, qualifiers, source) do
    qualifiers = qualifiers || %{}

    with %{} = parameter <- param_or_warn(state, module, param),
         %{} = row <- Storage.to_row(value, parameter, timestamp(qualifiers), qualifiers),
         fingerprint = Storage.fingerprint(row),
         last = Map.get(state.last, parameter.id),
         true <- keep?(source, fingerprint, last) do
      %{
        state
        | batch: [row | state.batch],
          batch_size: state.batch_size + 1,
          last: Map.put(state.last, parameter.id, fingerprint)
      }
    else
      _ -> state
    end
  end

  # anything the node sends is kept, except an exact repeat of the last reading
  defp keep?(_source, _fingerprint, nil), do: true
  defp keep?(:live, fingerprint, last), do: not Storage.same?(fingerprint, last)

  # a value known from before the writer started is only new if it is newer
  defp keep?(:initial, {ts, _, _}, {last_ts, _, _}), do: DateTime.compare(ts, last_ts) == :gt

  defp param_or_warn(state, module, param) do
    case Map.get(state.parameters, {module, param}) do
      nil ->
        Logger.warning("Parameter not in cache (skipping): #{module}:#{param}")
        nil

      parameter ->
        parameter
    end
  end

  defp timestamp(%{t: t}), do: t
  defp timestamp(%{"t" => t}), do: t
  defp timestamp(_qualifiers), do: DateTime.utc_now()

  defp maybe_flush(%{batch_size: size} = state) when size >= @max_batch_size, do: flush(state)
  defp maybe_flush(state), do: state

  defp flush(%{batch: []} = state), do: state

  defp flush(state) do
    batch = state.batch
    Task.start(fn -> write(batch) end)
    %{state | batch: [], batch_size: 0}
  end

  defp schedule_batch_flush do
    Process.send_after(self(), :flush_parameter_batch, @batch_interval)
  end

  # -- writing -----------------------------------------------------------------

  defp write([]), do: :ok

  defp write(batch) do
    rows = Enum.reverse(batch)

    case SecNodes.insert_readings(rows) do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{status: :partial_success, error_count: errors, errors: samples} ->
        Logger.warning(
          "Inserted #{length(rows) - errors}/#{length(rows)} readings; e.g. #{inspect(Enum.take(samples, 3))}"
        )

      %Ash.BulkResult{errors: errors} ->
        Logger.error("Failed to insert #{length(rows)} readings: #{inspect(errors)}")
    end
  end

  # {module_name, parameter_name} => parameter
  defp build_parameter_cache(node_uuid) do
    {:ok, parameters} = SecNodes.parameters_of_node(node_uuid)
    Map.new(parameters, &{{&1.module.name, &1.name}, &1})
  end

  # parameter_id => fingerprint of its newest stored reading. If this fails
  # the writer still starts: a few repeats stored beat recording nothing.
  defp load_last_readings(parameters) do
    parameters
    |> Map.values()
    |> Enum.map(& &1.id)
    |> SecNodes.latest_readings()
    |> Map.new(fn {id, reading} -> {id, Storage.fingerprint(reading)} end)
  rescue
    error ->
      Logger.error("Could not load the last readings, repeats may be stored: #{inspect(error)}")
      %{}
  end
end
