defmodule SecantService.NodeDBWriter do
  @batch_interval 10_000
  @max_batch_size 1000
  @max_buffered 100_000
  @max_retry_delay 30_000

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

  ## Writing

  One write is in flight at a time, in a task, so a slow database neither
  blocks this process nor piles up connections. Readings arriving meanwhile
  are buffered and go out with the next write, oldest first.

    * When the database can't be reached, the batch goes back to the front
      of the buffer and is retried, backing off up to #{div(@max_retry_delay, 1000)} s.
    * When the database rejects a batch for its data (say a reading of a
      parameter that was deleted meanwhile), it is split until the rejected
      readings are found; only those are dropped, and logged.
    * The buffer holds at most #{@max_buffered} readings. Beyond that, during a
      long outage, the oldest are dropped, and logged.

  Each write emits `[:secant_service, :node_db_writer, :write]` telemetry
  (`duration`, `rows`, `dropped`); dropping readings from a full
  buffer emits `[:secant_service, :node_db_writer, :overflow]` (`dropped`).
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

  # Time to store the buffer when the node services stop
  def child_spec(node_db) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [node_db]}, shutdown: 30_000}
  end

  @impl true
  def init(node_db) do
    # Trap exits so terminate/2 runs (and stores the buffer) when the node
    # services are shut down, e.g. on a description change.
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
       batch_size: 0,
       # %{task: Task.t(), rows: rows} of the write in flight
       in_flight: nil,
       # delay of the pending retry after a failed write, nil when none
       retry_delay: nil
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

  def handle_info(:retry_write, state) do
    {:noreply, flush(%{state | retry_delay: nil}, :retry)}
  end

  # The write in flight is done
  def handle_info({ref, result}, %{in_flight: %{task: %{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, written(state, result)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{in_flight: %{task: %{ref: ref}}} = state
      ) do
    Logger.error("Writing readings of #{state.equipment_id} crashed: #{inspect(reason)}")
    {:noreply, written(state, {:retry, state.in_flight.rows, 0})}
  end

  # The node services start after the node was described; whatever the node
  # reported before that is in NodeValues. Buffered first, so it is written
  # before anything that arrives later.
  def handle_info(:write_initial_values, state) do
    case SecantService.NodeValues.get_values(state.node_id) do
      {:ok, values} ->
        before = state.batch_size

        state =
          Enum.reduce(state.parameters, state, fn {{module, param}, _}, state ->
            case get_in(values, [module, param]) do
              %{data_report: [value, qualifiers]} ->
                add(state, module, param, value, qualifiers, :initial)

              _ ->
                state
            end
          end)

        Logger.info(
          "Writing #{state.batch_size - before} initial values for #{state.equipment_id}"
        )

        {:noreply, flush(state)}

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
    # (e.g. on a description change). The write in flight finishes first.
    unsent =
      case state.in_flight do
        nil ->
          []

        %{task: task, rows: rows} ->
          case Task.yield(task, 10_000) || Task.shutdown(task) do
            {:ok, {:ok, _dropped}} -> []
            {:ok, {:retry, left, _dropped}} -> left
            _ -> rows
          end
      end

    rows = unsent ++ Enum.reverse(state.batch)

    case insert(rows) do
      {:ok, _dropped} ->
        :ok

      {:retry, left, _dropped} ->
        Logger.error("Lost #{length(left)} readings of #{state.equipment_id} on stop")
    end

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
      # `last` is what was received, not what is stored yet: a reading still
      # buffered is retried until it is stored, so a repeat of it is a repeat.
      %{
        state
        | batch: [row | state.batch],
          batch_size: state.batch_size + 1,
          last: Map.put(state.last, parameter.id, fingerprint)
      }
      |> limit_buffer()
    else
      _ -> state
    end
  end

  # anything the node sends is kept, except an exact repeat of the last reading
  defp keep?(_source, _fingerprint, nil), do: true
  defp keep?(:live, fingerprint, last), do: not Storage.same?(fingerprint, last)

  # a value known from before the writer started is only new if it is newer
  defp keep?(:initial, {ts, _, _}, {last_ts, _, _}), do: DateTime.compare(ts, last_ts) == :gt

  # Trims in chunks, not on every reading, so a full buffer costs O(1) per reading
  defp limit_buffer(%{batch_size: size} = state) when size > @max_buffered + @max_batch_size do
    dropped = size - @max_buffered

    Logger.error(
      "Readings of #{state.equipment_id} can't be written, dropped the oldest #{dropped}"
    )

    :telemetry.execute([:secant_service, :node_db_writer, :overflow], %{dropped: dropped}, %{
      equipment_id: state.equipment_id
    })

    %{state | batch: Enum.take(state.batch, @max_buffered), batch_size: @max_buffered}
  end

  defp limit_buffer(state), do: state

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

  defp schedule_batch_flush do
    Process.send_after(self(), :flush_parameter_batch, @batch_interval)
  end

  # -- writing -----------------------------------------------------------------

  # Starts a write of the oldest buffered readings, unless one is in flight
  # or a retry is pending (then that comes first).
  defp flush(state, trigger \\ :batch)
  defp flush(%{batch: []} = state, _trigger), do: state
  defp flush(%{in_flight: %{}} = state, _trigger), do: state
  defp flush(%{retry_delay: delay} = state, :batch) when delay != nil, do: state

  defp flush(state, _trigger) do
    {newer, oldest} = Enum.split(state.batch, Kernel.max(state.batch_size - @max_batch_size, 0))
    rows = Enum.reverse(oldest)

    task =
      Task.Supervisor.async_nolink(SecantService.TaskSupervisor, fn -> timed_insert(rows) end)

    %{
      state
      | batch: newer,
        batch_size: length(newer),
        in_flight: %{task: task, rows: rows}
    }
  end

  defp written(state, {:ok, _dropped}) do
    state = %{state | in_flight: nil, retry_delay: nil}
    # more than a batch was buffered (e.g. after an outage): keep going
    if state.batch_size >= @max_batch_size, do: flush(state), else: state
  end

  defp written(state, {:retry, rows, _dropped}) do
    delay =
      if state.retry_delay,
        do: min(state.retry_delay * 2, @max_retry_delay),
        else: Application.get_env(:secant_service, :writer_retry_delay, 1_000)

    Logger.warning(
      "Could not write #{length(rows)} readings of #{state.equipment_id}, retrying in #{delay} ms"
    )

    Process.send_after(self(), :retry_write, delay)

    %{
      state
      | in_flight: nil,
        retry_delay: delay,
        # back in front of the buffer: they are older than anything in it
        batch: state.batch ++ Enum.reverse(rows),
        batch_size: state.batch_size + length(rows)
    }
    |> limit_buffer()
  end

  defp timed_insert(rows) do
    start = System.monotonic_time()
    result = insert(rows)

    dropped = elem(result, tuple_size(result) - 1)

    :telemetry.execute(
      [:secant_service, :node_db_writer, :write],
      %{duration: System.monotonic_time() - start, rows: length(rows), dropped: dropped},
      %{}
    )

    result
  end

  @doc false
  # Inserts the rows: `{:ok, dropped}`, or `{:retry, unsent_rows, dropped}`
  # when the database could not be reached. Rows the database rejects are
  # found by splitting the batch, and dropped.
  def insert([]), do: {:ok, 0}

  def insert(rows) do
    case attempt(rows) do
      :ok ->
        {:ok, 0}

      {:rows_rejected, count} ->
        {:ok, count}

      :unreachable ->
        {:retry, rows, 0}

      {:rejected, error} when length(rows) == 1 ->
        Logger.error("Dropped a reading the database rejects: #{inspect(rows)}: #{error}")
        {:ok, 1}

      {:rejected, _error} ->
        {first, second} = Enum.split(rows, div(length(rows), 2))

        case insert(first) do
          {:ok, dropped} ->
            case insert(second) do
              {:ok, more} -> {:ok, dropped + more}
              {:retry, left, more} -> {:retry, left, dropped + more}
            end

          {:retry, left, dropped} ->
            {:retry, left ++ second, dropped}
        end
    end
  end

  defp attempt(rows) do
    case inserter().(rows) do
      %Ash.BulkResult{status: :success} ->
        :ok

      # rows Ash itself refused (e.g. a value it can't cast); the others are stored
      %Ash.BulkResult{status: :partial_success, error_count: count, errors: errors} ->
        Logger.error(
          "Dropped #{count}/#{length(rows)} readings; e.g. #{inspect(Enum.take(errors, 3))}"
        )

        {:rows_rejected, count}

      %Ash.BulkResult{errors: errors} ->
        if rejected?(errors), do: {:rejected, Exception.message(hd(errors))}, else: :unreachable
    end
  rescue
    error ->
      Logger.warning("Writing readings raised: #{Exception.message(error)}")
      :unreachable
  catch
    :exit, reason ->
      Logger.warning("Writing readings exited: #{inspect(reason, limit: 5)}")
      :unreachable
  end

  # The data was refused: Ash maps constraint violations (e.g. a deleted
  # parameter) to Invalid errors; otherwise SQLSTATE class 22 (data exception)
  # or 23 (integrity violation). Anything else (connection, timeout, ...) may
  # pass when retried.
  defp rejected?(errors) do
    Enum.any?(errors, &is_struct(&1, Ash.Error.Invalid)) or
      match?(
        %Postgrex.Error{postgres: %{pg_code: <<class::binary-size(2), _::binary>>}}
        when class in ["22", "23"],
        find_postgrex_error(errors)
      )
  end

  defp find_postgrex_error(%Postgrex.Error{} = error), do: error

  defp find_postgrex_error(list) when is_list(list),
    do: Enum.find_value(list, &find_postgrex_error/1)

  defp find_postgrex_error(%{} = map) do
    map |> Map.delete(:__struct__) |> Map.values() |> find_postgrex_error()
  end

  defp find_postgrex_error(_other), do: nil

  # A seam for tests that need a failing database
  defp inserter do
    Application.get_env(:secant_service, :insert_readings, &SecNodes.insert_readings/1)
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
