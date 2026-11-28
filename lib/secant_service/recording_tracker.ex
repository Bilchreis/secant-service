defmodule SecantService.RecordingTracker do
  @heartbeat_interval 10_000
  # an open span this much older than its heartbeat is not adopted
  @adopt_within 45_000
  # wall clock ahead of the monotonic clock by more than this: a suspend
  @suspend_threshold 30_000
  # a value update this recent counts as the start of recording
  @lookback 2_000
  @stop_budget 5_000

  @moduledoc """
  Records when a session's node was being recorded, as
  `SecantService.SecNodes.RecordingSpan`s, so the plots can break their lines
  where nothing was recorded (see `SecantService.PlotDB.Gaps`). One per
  session, the last child of `SecantService.NodeServices`.

  ## When a span is open

  The tracker keeps the node's last known `state`, `active` and `uuid`, from
  a snapshot at start, `state_change` reports (all three) and `conn_state`
  reports (`active` only). Recording is possible while the node is
  `:initialized`, `active`, and reported under this session's uuid.

  Each time that becomes true the tracker *arms*, and the next value update
  opens a span. On a reconnect `active` is stale (the client keeps it across
  a disconnect), so only a value update shows that values flow again. The
  client's parser can broadcast an activation's first values before the
  state machine reports `active`, so a value update less than
  #{div(@lookback, 1000)} s before arming counts too, if it came on the
  current connection (after the last `:initialized` report) and after the
  last close. At start, a node that is already active opens a span at once:
  its values were flowing before the services started.

  A span closes as `:disconnected` (the node left `:initialized`, or its
  state machine died), `:deactivated` (`active` turned false), `:stopped` (a
  report under another uuid, or a clean stop of the services), or
  `:interrupted` (a suspend, see below, or a span found left open).

  A heartbeat every #{div(@heartbeat_interval, 1000)} s moves the open span's
  `alive_until` on.

  ## Suspend

  Before it handles anything, the tracker compares the wall-clock time
  (`System.os_time`) and the monotonic time elapsed since its previous
  check. The monotonic clock doesn't advance while the host is suspended
  (ERTS on Linux reads `CLOCK_MONOTONIC`, as
  `erlang:system_info(os_monotonic_time_source)` reports on the dev
  machine), the wall clock does; a busy BEAM advances both alike. More than
  #{div(@suspend_threshold, 1000)} s apart, and the open span is closed at its
  last heartbeat as `:interrupted`. The tracker arms again, so the next
  value update opens a new span.

  ## Restarts

  At start the tracker reads its session's open span, if any, before it
  opens one. One alive within the last #{div(@adopt_within, 1000)} s, with
  recording still possible, is carried on (same id); any other is closed at
  its `alive_until` as `:interrupted`. A crash of the tracker leaves its span
  open for that. A clean stop (`:normal`, `:shutdown`, which is also how a
  crashing sibling stops it) closes it as `:stopped`, writing what is
  pending within #{div(@stop_budget, 1000)} s.

  ## Writing

  Every change is an upsert of the whole row, queued in order and written
  by one linked task at a time, so a slow database never delays a
  heartbeat or a clock check. Changes that fail because the database can't
  be reached are retried on the next heartbeat (`SecantService.DBErrors`).
  An open refused by the one-open-span index re-reads the open span and
  adopts or closes it. Other failures are logged and dropped.

  Each start and end of recording is also passed to the node's plot cache
  (`SecantService.PlotCache.recording/4`, with the reason it stopped), for the live plots.

  The clock (`:recording_tracker_clock`, a function returning
  `{os_ms, monotonic_ms}`), the heartbeat interval
  (`:recording_tracker_interval`) and the write (`:record_span`) can be swapped through the application
  environment, for tests.
  """
  use GenServer
  require Logger

  alias SecantService.DBErrors
  alias SecantService.PlotCache
  alias SecantService.SecNodes
  alias SecantService.Topics

  @client_pubsub :secant_client_pubsub

  def start_link(node_db), do: GenServer.start_link(__MODULE__, node_db)

  def child_spec(node_db) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [node_db]},
      shutdown: @stop_budget + 3_000
    }
  end

  @impl true
  def init(node_db) do
    Process.flag(:trap_exit, true)

    state = %{
      node_id: node_db.node_id,
      uuid: node_db.uuid,
      address: Topics.node_address(node_db.node_id),
      # last known state/active/uuid of the node, nil until the snapshot
      node: nil,
      monitor: nil,
      # :starting until the left-open span is settled, then :idle, :armed
      # or :recording
      status: :starting,
      span: nil,
      last_update_at: nil,
      last_initialized_at: nil,
      last_close_at: nil,
      clock: clock(),
      pending: [],
      in_flight: nil
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    Phoenix.PubSub.subscribe(@client_pubsub, "state_change")
    Phoenix.PubSub.subscribe(@client_pubsub, "secop_conn_state")
    Phoenix.PubSub.subscribe(@client_pubsub, Topics.value_update(state.node_id))
    schedule_beat()

    {:noreply, state |> snapshot() |> settle_left_open() |> flush()}
  end

  @impl true
  def handle_info(:beat, state) do
    schedule_beat()

    state =
      state
      |> check_clock()
      |> snapshot()
      |> settle_left_open()
      |> heartbeat()
      |> release()
      |> flush()

    {:noreply, state}
  end

  def handle_info({:state_change, address, node_state}, %{address: address} = state) do
    state = check_clock(state)
    now = now_ms(state)

    node = %{state: node_state.state, active: node_state.active, uuid: node_state.uuid}

    state =
      if node.state == :initialized,
        do: %{state | last_initialized_at: now},
        else: state

    {:noreply, %{state | node: node} |> monitor() |> evaluate() |> flush()}
  end

  def handle_info({:state_change, _other, _}, state), do: {:noreply, state}

  def handle_info({:conn_state, address, active}, %{address: address, node: %{} = node} = state) do
    state = check_clock(state)
    {:noreply, %{state | node: %{node | active: active}} |> evaluate() |> flush()}
  end

  def handle_info({:conn_state, _address, _active}, state), do: {:noreply, state}

  def handle_info({:value_update, _module, _param, _report}, state) do
    state = check_clock(state)
    now = now_ms(state)
    state = %{state | last_update_at: now}

    state =
      case state.status do
        :armed -> open(state, now)
        _ -> state
      end

    {:noreply, flush(state)}
  end

  # the node's state machine died: no connection
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state) do
    state = check_clock(state)
    node = state.node && %{state.node | state: :disconnected}
    {:noreply, %{state | monitor: nil, node: node} |> evaluate() |> flush()}
  end

  # a write is done
  def handle_info({ref, result}, %{in_flight: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> written(result) |> flush()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{in_flight: %{ref: ref}} = state) do
    Logger.warning("Writing a recording span crashed: #{inspect(reason)}")
    {:noreply, %{state | in_flight: nil}}
  end

  # exits of finished write tasks (linked; we trap exits)
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    state = check_clock(state)

    if clean?(reason) and state.status == :recording do
      now = now_ms(state)
      PlotCache.recording(state.node_id, :stopped, now, :stopped)
      state |> close(now, :stopped, notify?: false) |> drain()
    else
      drain(state)
    end

    :ok
  end

  defp clean?(reason), do: reason in [:normal, :shutdown] or match?({:shutdown, _}, reason)

  # -- the node --------------------------------------------------------------------

  # The node's state from its state machine, once (and again while unknown)
  defp snapshot(%{node: nil} = state) do
    case Registry.lookup(SecantClient.Registry.NodeStatem, state.node_id) do
      [{pid, _}] ->
        case get_state(pid) do
          {:ok, node_state} ->
            node = %{state: node_state.state, active: node_state.active, uuid: node_state.uuid}
            %{state | node: node, monitor: Process.monitor(pid)}

          :error ->
            state
        end

      [] ->
        state
    end
  end

  defp snapshot(state), do: state

  defp get_state(pid) do
    case :gen_statem.call(pid, :get_state, 5_000) do
      {:ok, node_state} -> {:ok, node_state}
      _ -> :error
    end
  catch
    :exit, _ -> :error
  end

  # monitors the state machine again after it restarted
  defp monitor(%{monitor: nil} = state) do
    case Registry.lookup(SecantClient.Registry.NodeStatem, state.node_id) do
      [{pid, _}] -> %{state | monitor: Process.monitor(pid)}
      [] -> state
    end
  end

  defp monitor(state), do: state

  defp possible?(%{node: %{state: :initialized, active: true, uuid: uuid}, uuid: uuid}),
    do: true

  defp possible?(_state), do: false

  # -- spans -----------------------------------------------------------------------

  # At start: the open span left by an earlier tracker of this session, if
  # any, is carried on or closed before a span opens. Waits for the snapshot
  # and for the database.
  defp settle_left_open(%{status: :starting, node: %{}} = state) do
    case read_open_span(state.uuid) do
      {:ok, left_open} ->
        state = %{state | status: :idle}
        now = now_ms(state)

        case left_open do
          nil ->
            start(state, now)

          span ->
            alive = DateTime.to_unix(span.alive_until, :millisecond)

            if possible?(state) and now - alive < @adopt_within do
              Logger.info("Carrying on the recording span of #{state.uuid}")
              %{state | status: :recording, span: from_record(span)} |> beat_row()
            else
              state
              |> enqueue(close_row(from_record(span), alive, :interrupted, state.uuid))
              |> start(now)
            end
        end

      {:error, error} ->
        Logger.warning("Could not read the open recording span: #{inspect(error, limit: 5)}")
        state
    end
  end

  defp settle_left_open(state), do: state

  # at start, values were flowing already if the node is active
  defp start(state, now) do
    if possible?(state), do: open(state, now), else: state
  end

  # Opens, arms or closes as the node's state now allows
  defp evaluate(%{status: :starting} = state), do: state

  defp evaluate(state) do
    now = now_ms(state)

    case {possible?(state), state.status} do
      {true, :idle} -> arm(state, now)
      {false, :armed} -> %{state | status: :idle}
      {false, :recording} -> close(state, now, close_reason(state))
      _ -> state
    end
  end

  defp arm(state, now) do
    since = max(state.last_initialized_at || 0, state.last_close_at || 0)

    case state.last_update_at do
      at when is_integer(at) and at > since and now - at < @lookback -> open(state, at)
      _ -> %{state | status: :armed}
    end
  end

  defp close_reason(%{node: %{uuid: uuid}, uuid: mine}) when uuid != mine, do: :stopped
  defp close_reason(%{node: %{state: :initialized}}), do: :deactivated
  defp close_reason(_state), do: :disconnected

  defp open(state, at) do
    span = %{id: Ecto.UUID.generate(), started_at: at, alive_until: max(at, now_ms(state))}
    PlotCache.recording(state.node_id, :resumed, at)

    %{state | status: :recording, span: span}
    |> enqueue(row(state, span))
  end

  defp close(state, at, reason, opts \\ []) do
    if Keyword.get(opts, :notify?, true),
      do: PlotCache.recording(state.node_id, :stopped, at, reason)

    %{state | status: :idle, span: nil, last_close_at: at}
    |> enqueue(close_row(state.span, at, reason, state.uuid))
  end

  defp heartbeat(%{status: :recording, span: span} = state) do
    %{state | span: %{span | alive_until: max(span.alive_until, now_ms(state))}}
    |> beat_row()
  end

  defp heartbeat(state), do: state

  defp beat_row(state), do: enqueue(state, row(state, state.span))

  defp row(state, span) do
    %{
      id: span.id,
      sec_node_id: state.uuid,
      started_at: ms_to_datetime(span.started_at),
      alive_until: ms_to_datetime(span.alive_until),
      ended_at: nil,
      end_reason: nil
    }
  end

  # a span ends where it was last alive
  defp close_row(span, at, reason, sec_node_id) do
    %{
      id: span.id,
      sec_node_id: sec_node_id,
      started_at: ms_to_datetime(span.started_at),
      alive_until: ms_to_datetime(at),
      ended_at: ms_to_datetime(at),
      end_reason: reason
    }
  end

  defp from_record(record) do
    %{
      id: record.id,
      started_at: DateTime.to_unix(record.started_at, :millisecond),
      alive_until: DateTime.to_unix(record.alive_until, :millisecond)
    }
  end

  # -- clock -----------------------------------------------------------------------

  # A suspend shows as the wall clock running ahead of the monotonic one:
  # the open span ends at its last heartbeat.
  defp check_clock(state) do
    {os, mono} = now = clock()
    {prev_os, prev_mono} = state.clock
    state = %{state | clock: now}

    if os - prev_os - (mono - prev_mono) > @suspend_threshold and state.status == :recording do
      Logger.info("Host was suspended, recording of #{state.uuid} interrupted")
      state = close(state, state.span.alive_until, :interrupted)
      if possible?(state), do: %{state | status: :armed}, else: state
    else
      state
    end
  end

  defp clock do
    case Application.get_env(:secant_service, :recording_tracker_clock) do
      nil -> {System.os_time(:millisecond), System.monotonic_time(:millisecond)}
      fun -> fun.()
    end
  end

  defp now_ms(%{clock: {os, _mono}}), do: os

  # tests swap in a failing write (`:record_span`)
  defp writer, do: Application.get_env(:secant_service, :record_span, &SecNodes.record_span/1)

  defp ms_to_datetime(ms), do: DateTime.from_unix!(ms * 1000, :microsecond)

  defp schedule_beat do
    interval =
      Application.get_env(:secant_service, :recording_tracker_interval, @heartbeat_interval)

    Process.send_after(self(), :beat, interval)
  end

  # -- writing ---------------------------------------------------------------------

  # Rows are whole: a newer row of a span replaces its pending one in place
  defp enqueue(state, %{id: id} = row) do
    pending =
      if Enum.any?(state.pending, &(&1.id == id)),
        do: Enum.map(state.pending, &if(&1.id == id, do: row, else: &1)),
        else: state.pending ++ [row]

    %{state | pending: pending}
  end

  defp flush(%{in_flight: nil, pending: [row | _]} = state) do
    task = Task.async(fn -> writer().(row) end)
    %{state | in_flight: %{ref: task.ref, task: task, row: row}}
  end

  defp flush(state), do: state

  defp written(%{in_flight: %{row: row}} = state, result) do
    state = %{state | in_flight: nil}

    case result do
      {:ok, _} ->
        done(state, row)

      {:error, error} ->
        cond do
          DBErrors.transient?(error) ->
            # retried on the next heartbeat
            hold(state)

          open_conflict?(row, error) ->
            state |> done(row) |> resolve_conflict(row)

          true ->
            Logger.error("Dropped a recording span change: #{inspect(error, limit: 5)}")
            done(state, row)
        end
    end
  end

  # the head of the queue is written, unless a newer row replaced it meanwhile
  defp done(%{pending: [row | rest]} = state, row), do: %{state | pending: rest}
  defp done(state, _row), do: state

  # waits for the next heartbeat: nothing is written until then
  defp hold(state), do: %{state | in_flight: :held}

  defp release(%{in_flight: :held} = state), do: %{state | in_flight: nil}
  defp release(state), do: state

  defp open_conflict?(%{ended_at: nil}, error),
    do: inspect(error, limit: :infinity) =~ "recording_spans_one_open_per_session_index"

  defp open_conflict?(_row, _error), do: false

  # Another span of this session is open (written by an earlier tracker
  # meanwhile): carried on, or closed before this one opens again.
  defp resolve_conflict(state, row) do
    case read_open_span(state.uuid) do
      {:ok, %{} = other} ->
        alive = DateTime.to_unix(other.alive_until, :millisecond)
        other_span = from_record(other)

        if (state.span && state.span.id == row.id) and now_ms(state) - alive < @adopt_within do
          span = %{state.span | id: other.id, started_at: other_span.started_at}

          pending =
            Enum.map(state.pending, &if(&1.id == row.id, do: %{&1 | id: other.id}, else: &1))

          %{state | span: span, pending: pending} |> beat_row()
        else
          state
          |> Map.update!(:pending, &[close_row(other_span, alive, :interrupted, state.uuid) | &1])
          |> enqueue(row)
        end

      _ ->
        # unreadable: try the open again on the next heartbeat
        %{state | pending: [row | state.pending]} |> hold()
    end
  end

  # The open span of a session; an unreachable database (also as an exit,
  # e.g. no connection checked out in time) is an error, not a crash
  defp read_open_span(uuid) do
    SecNodes.open_span(uuid)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  # On stop: what is pending is written within the budget
  defp drain(state) do
    deadline = System.monotonic_time(:millisecond) + @stop_budget

    pending =
      case state.in_flight do
        %{task: task, row: row} ->
          case Task.yield(task, remaining(deadline)) || Task.shutdown(task, :brutal_kill) do
            {:ok, {:ok, _}} -> without_head(state.pending, row)
            _ -> state.pending
          end

        _ ->
          state.pending
      end

    lost =
      Enum.reduce(pending, 0, fn
        row, 0 ->
          task = Task.async(fn -> writer().(row) end)

          case Task.yield(task, remaining(deadline)) || Task.shutdown(task, :brutal_kill) do
            {:ok, {:ok, _}} -> 0
            _ -> 1
          end

        _row, lost ->
          lost + 1
      end)

    if lost > 0, do: Logger.warning("Could not write #{lost} recording span changes on stop")
  end

  defp without_head([row | rest], row), do: rest
  defp without_head(pending, _row), do: pending

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
