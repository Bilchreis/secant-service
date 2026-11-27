defmodule SecantService.RecordingTrackerTest do
  # the clock and interval are global application settings
  use SecantService.DataCase, async: false

  import SecantService.NodeFixtures,
    only: [unique_node_id: 0, send_value_update: 4, eventually: 1]

  require Ash.Query

  alias SecantService.FakeNodeStatem
  alias SecantService.RecordingTracker
  alias SecantService.SecNodes
  alias SecantService.SecNodes.RecordingSpan
  alias SecantService.Topics

  @t0 1_795_000_000_000

  setup do
    # supervised, so it outlives the tracker (stopped first) in teardown
    clock = start_supervised!({Agent, fn -> {@t0, 0} end}, id: :clock)

    Application.put_env(:secant_service, :recording_tracker_clock, fn ->
      Agent.get(clock, & &1)
    end)

    # beats only when a test sends one
    Application.put_env(:secant_service, :recording_tracker_interval, 3_600_000)

    on_exit(fn ->
      Application.delete_env(:secant_service, :recording_tracker_clock)
      Application.delete_env(:secant_service, :recording_tracker_interval)
      Application.delete_env(:secant_service, :record_span)
    end)

    node = generate(sec_node())
    node_id = unique_node_id()
    Phoenix.PubSub.subscribe(SecantService.PubSub, Topics.plot_data(node_id))

    %{clock: clock, node: node, node_id: node_id, node_db: %{node_id: node_id, uuid: node.uuid}}
  end

  # -- helpers ---------------------------------------------------------------------

  # time passes: both clocks, or only the wall clock (a suspend)
  defp pass(clock, ms), do: Agent.update(clock, fn {os, mono} -> {os + ms, mono + ms} end)
  defp suspend(clock, ms), do: Agent.update(clock, fn {os, mono} -> {os + ms, mono} end)
  defp now(clock), do: clock |> Agent.get(& &1) |> elem(0)

  defp node_state(ctx, overrides) do
    Map.merge(%{state: :initialized, active: true, uuid: ctx.node.uuid}, Map.new(overrides))
  end

  defp start_statem(ctx, overrides \\ []) do
    start_supervised!({FakeNodeStatem, {ctx.node_id, node_state(ctx, overrides), []}})
  end

  # `id`: a tracker started after one was killed takes another id, since
  # the test supervisor may not have removed the dead one yet
  defp start_tracker(ctx, id \\ :tracker) do
    pid =
      start_supervised!(
        Supervisor.child_spec({RecordingTracker, ctx.node_db}, id: id, restart: :temporary)
      )

    sync(pid)
    pid
  end

  defp report(ctx, pid, overrides) do
    Phoenix.PubSub.broadcast(
      :secant_client_pubsub,
      "state_change",
      {:state_change, Topics.node_address(ctx.node_id), node_state(ctx, overrides)}
    )

    sync(pid)
  end

  defp conn_state(ctx, pid, active) do
    Phoenix.PubSub.broadcast(
      :secant_client_pubsub,
      "secop_conn_state",
      {:conn_state, Topics.node_address(ctx.node_id), active}
    )

    sync(pid)
  end

  defp value(ctx, pid) do
    send_value_update(ctx.node_id, "m", "value", [1.0, %{t: 1.0}])
    sync(pid)
  end

  defp beat(pid) do
    send(pid, :beat)
    sync(pid)
  end

  defp sync(pid), do: :sys.get_state(pid)

  # the session's spans once every pending change is written
  defp spans(ctx, pid) do
    eventually(fn ->
      state = :sys.get_state(pid)
      state.pending == [] and state.in_flight == nil
    end)

    RecordingSpan
    |> Ash.Query.filter(sec_node_id == ^ctx.node.uuid)
    |> Ash.Query.sort(started_at: :asc)
    |> Ash.read!()
  end

  defp ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)
  defp ms(nil), do: nil

  # -- opening ---------------------------------------------------------------------

  test "opens at once when the node is active at start, with no later value update", ctx do
    start_statem(ctx)
    pid = start_tracker(ctx)

    assert [%{ended_at: nil} = span] = spans(ctx, pid)
    assert ms(span.started_at) == @t0
    assert_receive {:recording, :resumed, @t0}
  end

  test "a node inactive at start opens with the first value update after its activation", ctx do
    start_statem(ctx, active: false)
    pid = start_tracker(ctx)
    assert spans(ctx, pid) == []

    pass(ctx.clock, 5_000)
    conn_state(ctx, pid, true)
    assert spans(ctx, pid) == []

    pass(ctx.clock, 1_000)
    value(ctx, pid)
    assert [%{ended_at: nil} = span] = spans(ctx, pid)
    assert ms(span.started_at) == @t0 + 6_000
  end

  test "a reconnect opens at the first value update, not at the stale active report", ctx do
    start_statem(ctx)
    pid = start_tracker(ctx)

    pass(ctx.clock, 10_000)
    report(ctx, pid, state: :disconnected)
    assert [%{end_reason: :disconnected} = first] = spans(ctx, pid)
    assert ms(first.ended_at) == @t0 + 10_000
    assert_receive {:recording, :stopped, _}

    # reconnected, `active` still true from before; no values yet
    pass(ctx.clock, 60_000)
    report(ctx, pid, state: :initialized)
    assert [_closed] = spans(ctx, pid)

    pass(ctx.clock, 500)
    value(ctx, pid)
    assert [_closed, %{ended_at: nil} = second] = spans(ctx, pid)
    assert ms(second.started_at) == @t0 + 70_500
  end

  test "a value from before a quick reconnect doesn't reopen a span", ctx do
    start_statem(ctx)
    pid = start_tracker(ctx)

    value(ctx, pid)
    report(ctx, pid, state: :disconnected)
    pass(ctx.clock, 1_000)
    report(ctx, pid, state: :initialized)

    assert [%{end_reason: :disconnected}] = spans(ctx, pid)
  end

  test "deactivate and reactivate, with the first values just before the report", ctx do
    start_statem(ctx)
    pid = start_tracker(ctx)

    pass(ctx.clock, 10_000)
    conn_state(ctx, pid, false)
    assert [%{end_reason: :deactivated}] = spans(ctx, pid)

    # reactivated: the parser broadcasts values before the state machine
    # reports active, and no :initialized report comes
    pass(ctx.clock, 30_000)
    value(ctx, pid)
    pass(ctx.clock, 300)
    conn_state(ctx, pid, true)

    assert [_closed, %{ended_at: nil} = second] = spans(ctx, pid)
    assert ms(second.started_at) == @t0 + 40_000
  end

  # -- closing ---------------------------------------------------------------------

  test "the state machine dying closes as disconnected, also after a restart", ctx do
    start_statem(ctx)
    pid = start_tracker(ctx)

    stop_supervised!(FakeNodeStatem.child_spec({ctx.node_id, nil, []}).id)
    sync(pid)
    assert [%{end_reason: :disconnected}] = spans(ctx, pid)

    # a new state machine, reconnected; monitored again on its report
    start_statem(ctx)
    report(ctx, pid, state: :initialized)
    value(ctx, pid)
    assert [_, %{ended_at: nil}] = spans(ctx, pid)

    stop_supervised!(FakeNodeStatem.child_spec({ctx.node_id, nil, []}).id)
    sync(pid)
    assert [_, %{end_reason: :disconnected}] = spans(ctx, pid)
  end

  test "a report under another uuid closes as stopped and opens nothing", ctx do
    start_statem(ctx)
    pid = start_tracker(ctx)

    report(ctx, pid, uuid: Ecto.UUID.generate())
    value(ctx, pid)

    assert [%{end_reason: :stopped}] = spans(ctx, pid)
  end

  test "a clean stop closes as stopped and tells the live plots", ctx do
    start_statem(ctx)
    pid = start_tracker(ctx)
    beat(pid)
    assert_receive {:recording, :resumed, _}

    pass(ctx.clock, 5_000)
    stop_supervised!(:tracker)

    assert_receive {:recording, :stopped, stopped}
    assert stopped == @t0 + 5_000

    assert [%{end_reason: :stopped} = span] =
             RecordingSpan |> Ash.Query.filter(sec_node_id == ^ctx.node.uuid) |> Ash.read!()

    assert ms(span.ended_at) == @t0 + 5_000
  end

  # -- restarts --------------------------------------------------------------------

  test "a crashed tracker's span is carried on by the next one, under the same id", ctx do
    start_statem(ctx)
    pid = start_tracker(ctx)
    [%{id: id}] = spans(ctx, pid)

    Process.exit(pid, :kill)
    pass(ctx.clock, 5_000)
    pid = start_tracker(ctx, :restarted)
    beat(pid)

    assert [%{id: ^id, ended_at: nil} = span] = spans(ctx, pid)
    assert ms(span.alive_until) == @t0 + 5_000
  end

  test "a span left open long ago is closed at its last heartbeat as interrupted", ctx do
    start_statem(ctx)
    pid = start_tracker(ctx)
    pass(ctx.clock, 10_000)
    beat(pid)
    [_] = spans(ctx, pid)

    Process.exit(pid, :kill)
    pass(ctx.clock, 120_000)
    pid = start_tracker(ctx, :restarted)

    assert [%{end_reason: :interrupted} = old, %{ended_at: nil} = new] = spans(ctx, pid)
    assert ms(old.ended_at) == @t0 + 10_000
    assert ms(new.started_at) == @t0 + 130_000
  end

  test "an open refused because another span is open adopts that span", ctx do
    start_statem(ctx, active: false)
    pid = start_tracker(ctx)

    # written meanwhile by an earlier tracker of the session
    other = Ecto.UUID.generate()
    at = DateTime.from_unix!(@t0, :millisecond)

    SecNodes.record_span!(%{
      id: other,
      sec_node_id: ctx.node.uuid,
      started_at: at,
      alive_until: at
    })

    conn_state(ctx, pid, true)
    value(ctx, pid)
    pass(ctx.clock, 1_000)
    beat(pid)

    assert [%{id: ^other, ended_at: nil} = span] = spans(ctx, pid)
    assert ms(span.alive_until) == @t0 + 1_000
  end

  # -- suspend ---------------------------------------------------------------------

  test "a suspend ends the span at its last heartbeat", ctx do
    start_statem(ctx)
    pid = start_tracker(ctx)
    pass(ctx.clock, 10_000)
    beat(pid)

    suspend(ctx.clock, 600_000)
    pass(ctx.clock, 10_000)
    beat(pid)

    assert [%{end_reason: :interrupted} = span] = spans(ctx, pid)
    assert ms(span.ended_at) == @t0 + 10_000
    assert_receive {:recording, :stopped, stopped}
    assert stopped == @t0 + 10_000

    # the next value update opens a new span
    pass(ctx.clock, 1_000)
    value(ctx, pid)
    assert [_, %{ended_at: nil} = new] = spans(ctx, pid)
    assert ms(new.started_at) == now(ctx.clock)
  end

  test "a busy server's late heartbeat is no suspend", ctx do
    start_statem(ctx)
    pid = start_tracker(ctx)

    pass(ctx.clock, 45_000)
    beat(pid)

    assert [%{ended_at: nil} = span] = spans(ctx, pid)
    assert ms(span.alive_until) == @t0 + 45_000
  end

  test "a disconnect noticed right after a resume doesn't extend the span", ctx do
    start_statem(ctx)
    pid = start_tracker(ctx)
    pass(ctx.clock, 10_000)
    beat(pid)

    suspend(ctx.clock, 600_000)
    report(ctx, pid, state: :disconnected)
    pass(ctx.clock, 10_000)
    beat(pid)

    assert [%{end_reason: :interrupted} = span] = spans(ctx, pid)
    assert ms(span.ended_at) == @t0 + 10_000
  end

  # -- the database ----------------------------------------------------------------

  test "writes that can't reach the database wait, and nothing is lost", ctx do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Application.put_env(:secant_service, :record_span, fn _row ->
      Agent.update(calls, &(&1 + 1))
      {:error, %DBConnection.ConnectionError{message: "down"}}
    end)

    start_statem(ctx)
    pid = start_tracker(ctx)

    # the database is down for a minute; heartbeats go on
    for _ <- 1..6 do
      pass(ctx.clock, 10_000)
      beat(pid)
    end

    assert Agent.get(calls, & &1) >= 2
    assert RecordingSpan |> Ash.Query.filter(sec_node_id == ^ctx.node.uuid) |> Ash.read!() == []

    Application.delete_env(:secant_service, :record_span)
    beat(pid)

    assert [%{ended_at: nil} = span] = spans(ctx, pid)
    assert ms(span.started_at) == @t0
    assert ms(span.alive_until) == @t0 + 60_000
  end
end
