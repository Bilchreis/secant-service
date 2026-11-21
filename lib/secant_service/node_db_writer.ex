defmodule SecantService.NodeDBWriter do
  @batch_interval 10_000
  @max_batch_size 1000
  # A reading costs @row_weight plus one per array element (or 8 bytes of
  # text), so the buffer is bounded by memory, not count: about 50k scalar
  # readings or 1k spectra of 1000 points.
  @row_weight 20
  @max_buffered_weight 1_000_000
  @max_retry_delay 30_000
  # what terminate/2 may take; the child's shutdown is a little longer
  @stop_budget 25_000

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
  are buffered and go out with the next write, oldest first, at most
  #{@max_batch_size} per statement. Each statement is a transaction: all of
  it is stored or none.

    * When a write fails because the database can't be reached (or for a
      reason that may pass), the readings go back to the front of the buffer
      and are retried, backing off up to #{div(@max_retry_delay, 1000)} s.
    * When a write fails for any other reason, the batch is split until the
      failing readings are found. A single reading is dropped, and logged,
      only if the database answers otherwise: a reading of a parameter that
      was deleted, say, or one the code can't write.
    * The buffer is bounded by size (about 50k scalar readings, fewer for
      arrays). During an outage long enough to fill it, the oldest readings
      are dropped, and logged.
    * On stop (e.g. a description change) the buffer is written before the
      writer exits, within #{div(@stop_budget, 1000)} s.

  Delivery is at least once: a write cut off while committing may be sent
  again, so in rare cases a reading is stored twice.

  Telemetry:

    * `[:secant_service, :node_db_writer, :write]`: `duration`, `stored`
      readings; metadata `equipment_id`, `result` (`:ok` or `:retry`).
    * `[:secant_service, :node_db_writer, :dropped]`: `count`; metadata
      `equipment_id`, `reason` (`:rejected`, `:overflow` or `:stop`).
  """
  use GenServer
  require Logger

  alias SecantService.SecNodes
  alias SecantService.SecNodes.Reading
  alias SecantService.SecNodes.Reading.Storage

  @pubsub_name :secant_client_pubsub

  def start_link(node_db) do
    GenServer.start_link(__MODULE__, node_db,
      name: {:via, Registry, {Registry.NodeDBWriter, node_db.uuid}}
    )
  end

  def child_spec(node_db) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [node_db]},
      shutdown: @stop_budget + 5_000
    }
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
       # oldest first
       queue: :queue.new(),
       queued: 0,
       weight: 0,
       max_weight: config(:writer_max_buffered_weight, @max_buffered_weight),
       # %{task: Task.t(), rows: rows} of the write in flight
       in_flight: nil,
       # delay of the last retry while writes fail, nil once one succeeds
       retry_delay: nil,
       retry_pending?: false
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
    {:noreply, flush(%{state | retry_pending?: false})}
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
    {:noreply, written(state, {:retry, state.in_flight.rows, []})}
  end

  # The node services start after the node was described; whatever the node
  # reported before that is in NodeValues. Buffered first, so it is written
  # before anything that arrives later.
  def handle_info(:write_initial_values, state) do
    case SecantService.NodeValues.get_values(state.node_id) do
      {:ok, values} ->
        before = state.queued

        state =
          Enum.reduce(state.parameters, state, fn {{module, param}, _}, state ->
            case get_in(values, [module, param]) do
              %{data_report: [value, qualifiers]} ->
                add(state, module, param, value, qualifiers, :initial)

              _ ->
                state
            end
          end)

        Logger.info("Writing #{state.queued - before} initial values for #{state.equipment_id}")
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
    # Before the services are gone (e.g. on a description change): the write
    # in flight finishes, then the buffer is written, all within the budget.
    deadline = System.monotonic_time(:millisecond) + @stop_budget

    unsent =
      case state.in_flight do
        nil ->
          []

        %{task: task, rows: rows} ->
          unsent(state, task, rows, deadline)
      end

    case write_by(unsent ++ :queue.to_list(state.queue), deadline, state) do
      0 ->
        :ok

      lost ->
        Logger.error(
          "Lost #{lost} readings of #{state.equipment_id}: could not write them on stop"
        )

        dropped(state, :stop, lost)
    end

    Logger.info("Stopping NodeDBWriter for #{state.equipment_id} (#{inspect(reason)})")
    :ok
  end

  # Writes the rows in statements of @max_batch_size until the deadline;
  # returns how many could not be written.
  defp write_by(rows, deadline, state) do
    rows
    |> Enum.chunk_every(@max_batch_size)
    |> Enum.reduce(0, fn
      chunk, 0 ->
        task = Task.Supervisor.async_nolink(SecantService.TaskSupervisor, fn -> insert(chunk) end)
        state |> unsent(task, chunk, deadline) |> length()

      chunk, lost ->
        lost + length(chunk)
    end)
  end

  # The rows of a write that are not stored once it is done or the deadline
  # passed. A write cut off is rolled back, so all its rows are unsent.
  defp unsent(state, task, rows, deadline) do
    case Task.yield(task, remaining(deadline)) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, rejected}} ->
        report_rejected(state, rejected)
        []

      {:ok, {:retry, left, rejected}} ->
        report_rejected(state, rejected)
        left

      _ ->
        rows
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # -- batching ----------------------------------------------------------------

  defp add(state, module, param, value, qualifiers, source) do
    qualifiers = qualifiers || %{}

    with %{} = parameter <- param_or_warn(state, module, param),
         %{} = row <- Storage.to_row(value, parameter, timestamp(qualifiers), qualifiers),
         fingerprint = Storage.fingerprint(row),
         last = Map.get(state.last, parameter.id),
         true <- keep?(source, fingerprint, last) do
      # `last` is the newest reading received and not dropped: a buffered
      # reading is retried until it is stored, so a repeat of it is a repeat.
      %{
        state
        | queue: :queue.in(row, state.queue),
          queued: state.queued + 1,
          weight: state.weight + weight(row),
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

  # How much a buffered reading costs, roughly in machine words
  defp weight(row) do
    @row_weight +
      case Enum.find_value(Reading.value_columns(), &Map.get(row, &1)) do
        %{} = json -> json |> Map.values() |> Enum.map(&elements/1) |> Enum.sum()
        value -> elements(value)
      end
  end

  defp elements(list) when is_list(list), do: length(list)
  defp elements(text) when is_binary(text), do: div(byte_size(text), 8)
  defp elements(_other), do: 1

  # Over the limit, drops the oldest readings down to 90% of it, so a full
  # buffer trims (and logs) once per many readings, not on every one.
  defp limit_buffer(%{weight: weight, max_weight: max} = state) when weight > max do
    {state, count} = drop_oldest(state, div(max * 9, 10), 0)

    Logger.error(
      "Readings of #{state.equipment_id} can't be written, dropped the oldest #{count}"
    )

    dropped(state, :overflow, count)
    state
  end

  defp limit_buffer(state), do: state

  defp drop_oldest(%{weight: weight} = state, target, count) when weight <= target,
    do: {state, count}

  defp drop_oldest(state, target, count) do
    {{:value, row}, queue} = :queue.out(state.queue)

    # never stored: a resend of it must not count as a repeat
    last =
      if Map.get(state.last, row.parameter_id) == Storage.fingerprint(row),
        do: Map.delete(state.last, row.parameter_id),
        else: state.last

    state = %{
      state
      | queue: queue,
        queued: state.queued - 1,
        weight: state.weight - weight(row),
        last: last
    }

    drop_oldest(state, target, count + 1)
  end

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

  defp maybe_flush(%{queued: queued} = state) when queued >= @max_batch_size, do: flush(state)
  defp maybe_flush(state), do: state

  defp schedule_batch_flush do
    Process.send_after(self(), :flush_parameter_batch, @batch_interval)
  end

  # -- writing -----------------------------------------------------------------

  # Starts a write of the oldest buffered readings, unless one is in flight
  # or a retry is pending (then that comes first).
  defp flush(%{queued: 0} = state), do: state
  defp flush(%{in_flight: %{}} = state), do: state
  defp flush(%{retry_pending?: true} = state), do: state

  defp flush(state) do
    count = min(state.queued, @max_batch_size)
    {taken, rest} = :queue.split(count, state.queue)
    rows = :queue.to_list(taken)
    equipment_id = state.equipment_id

    task =
      Task.Supervisor.async_nolink(SecantService.TaskSupervisor, fn ->
        timed_insert(rows, equipment_id)
      end)

    %{
      state
      | queue: rest,
        queued: state.queued - count,
        weight: state.weight - Enum.sum_by(rows, &weight/1),
        in_flight: %{task: task, rows: rows}
    }
  end

  defp written(state, {:ok, rejected}) do
    report_rejected(state, rejected)
    state = %{state | in_flight: nil, retry_delay: nil}
    # more than a batch was buffered (e.g. after an outage): keep going
    if state.queued >= @max_batch_size, do: flush(state), else: state
  end

  defp written(state, {:retry, rows, rejected}) do
    report_rejected(state, rejected)

    delay =
      if state.retry_delay,
        do: min(state.retry_delay * 2, @max_retry_delay),
        else: config(:writer_retry_delay, 1_000)

    Logger.warning(
      "Could not write #{length(rows)} readings of #{state.equipment_id}, retrying in #{delay} ms"
    )

    Process.send_after(self(), :retry_write, delay)

    %{
      state
      | in_flight: nil,
        retry_delay: delay,
        retry_pending?: true,
        # back in front of the buffer: they are older than anything in it
        queue: :queue.join(:queue.from_list(rows), state.queue),
        queued: state.queued + length(rows),
        weight: state.weight + Enum.sum_by(rows, &weight/1)
    }
    |> limit_buffer()
  end

  defp report_rejected(_state, []), do: :ok

  defp report_rejected(state, rejected) do
    Logger.error(
      "Dropped #{length(rejected)} readings of #{state.equipment_id} that can't be stored, e.g. " <>
        hd(rejected)
    )

    dropped(state, :rejected, length(rejected))
  end

  defp dropped(state, reason, count) do
    :telemetry.execute([:secant_service, :node_db_writer, :dropped], %{count: count}, %{
      equipment_id: state.equipment_id,
      reason: reason
    })
  end

  defp timed_insert(rows, equipment_id) do
    start = System.monotonic_time()
    result = insert(rows)

    {stored, outcome} =
      case result do
        {:ok, rejected} -> {length(rows) - length(rejected), :ok}
        {:retry, left, rejected} -> {length(rows) - length(left) - length(rejected), :retry}
      end

    :telemetry.execute(
      [:secant_service, :node_db_writer, :write],
      %{duration: System.monotonic_time() - start, stored: stored},
      %{equipment_id: equipment_id, result: outcome}
    )

    result
  end

  @doc false
  # Inserts the rows: `{:ok, rejected}`, or `{:retry, unsent_rows, rejected}`
  # when the database could not be reached. `rejected` describes the rows
  # dropped because they can't be stored; they are found by splitting the
  # batch.
  def insert([]), do: {:ok, []}

  def insert(rows) do
    case attempt(rows) do
      :ok ->
        {:ok, []}

      {:partial, rejected} ->
        {:ok, rejected}

      :unreachable ->
        {:retry, rows, []}

      {:failed, reason} when length(rows) == 1 ->
        # A failure we can't tell from an outage: drop the row only if the
        # database answers otherwise
        if db_reachable?(),
          do: {:ok, ["#{inspect(hd(rows))}: #{reason}"]},
          else: {:retry, rows, []}

      {:failed, _reason} ->
        {first, second} = Enum.split(rows, div(length(rows), 2))

        case insert(first) do
          {:ok, rejected} ->
            case insert(second) do
              {:ok, more} -> {:ok, rejected ++ more}
              {:retry, left, more} -> {:retry, left, rejected ++ more}
            end

          {:retry, left, rejected} ->
            {:retry, left ++ second, rejected}
        end
    end
  end

  defp attempt(rows) do
    case inserter().(rows) do
      %Ash.BulkResult{status: :success} ->
        :ok

      # rows Ash itself refused (e.g. a value it can't cast); the others are stored
      %Ash.BulkResult{status: :partial_success, errors: errors} ->
        {:partial, Enum.map(errors, &describe/1)}

      %Ash.BulkResult{errors: errors} ->
        if transient?(errors), do: :unreachable, else: {:failed, describe(errors)}
    end
  rescue
    error -> if transient?(error), do: :unreachable, else: {:failed, Exception.message(error)}
  catch
    # e.g. no connection checked out in time
    :exit, _reason -> :unreachable
    kind, reason -> {:failed, "#{kind}: #{inspect(reason, limit: 5)}"}
  end

  defp describe([error | _]), do: describe(error)
  defp describe(error) when is_exception(error), do: Exception.message(error)
  defp describe(error), do: inspect(error, limit: 5)

  # Positive evidence that the failure may pass: no connection, or Postgres
  # saying so (SQLSTATE 08 connection, 40 rollback, 53 resources, 57
  # operator intervention, 55P03 lock not available).
  defp transient?(%DBConnection.ConnectionError{}), do: true
  defp transient?(%Ash.Error.Invalid.Unavailable{}), do: true

  defp transient?(%Postgrex.Error{
         postgres: %{pg_code: <<class::binary-size(2), _::binary>> = code}
       }),
       do: class in ["08", "40", "53", "57"] or code == "55P03"

  defp transient?(list) when is_list(list), do: Enum.any?(list, &transient?/1)
  defp transient?(%{} = map), do: map |> Map.delete(:__struct__) |> Map.values() |> transient?()
  # AshPostgres keeps some errors only as their formatted text
  defp transient?(text) when is_binary(text),
    do: String.contains?(text, "DBConnection.ConnectionError")

  defp transient?(_other), do: false

  defp db_reachable? do
    match?({:ok, _}, SecantService.Repo.query("SELECT 1"))
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # Tests swap in a failing insert (`:insert_readings`) and shorten the
  # retry delay (`:writer_retry_delay`) and buffer (`:writer_max_buffered_weight`).
  defp inserter, do: config(:insert_readings, &SecNodes.insert_readings/1)
  defp config(key, default), do: Application.get_env(:secant_service, key, default)

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
