# Design

## Context

See proposal.md (Why). The relevant state of the code:

**Sessions.** `NodeServices` is a per-session `rest_for_one` supervisor of `NodeValues`, `PlotCache` and `NodeDBWriter`. A session is a `SecNode` row.

`NodeStatem.init` generates a new uuid on every server boot (`node_statem.ex:127`); identity survives only a crash of the statem itself, through ETS. So a server restart, kill or deploy always starts new sessions, and `NodeManager` archives the old ones. The gaps that matter *inside* one session are:
- disconnects and deactivations;
- host suspends;
- restarts of the node services or of the tracker while the server runs.

**Client broadcasts.** `secant_client` broadcasts on `:secant_client_pubsub`:
- `"state_change"` carries `{:state_change, "host:port", node_state}`, with `state` (`:disconnected | :connected | :initialized | :could_not_initialize`), `active` and `uuid`;
- `"secop_conn_state"` carries `{:conn_state, "host:port", active}`, sent only when `active` changes.

`active` is not reset on disconnect. A reconnect broadcasts `:initialized` with `active` still `true`, before the new activation is acknowledged, and an acknowledgement that doesn't change `active` broadcasts nothing. Activation makes the node send its values; those are the first sign that it worked. `DashboardLive` already subscribes to both topics, for its header. `Topics.address/1` is private; the tracker needs it public (or a `Topics.node_address/1`).

**Plot data.** Plot data reaches the chart hook in several ways:
- the first load (`Builders.fetch_param_window/3`, `fetch_held_param_window/2`);
- `HistoryDB`'s `"fetch-chart-window"`, which holds setpoints through `held_window/3`;
- `HistoryDB`'s `"fetch-chart-overview"`;
- `HistoryDB`'s `"fetch-chart-range"`, which does no hold;
- live readings, which go `PlotCache` → `{:plot_data, batch}` → `DashboardLive` → `send_update(HistoryDB, value_update: …)` → `extend-chart-<id>`. `HistoryDB` drops them while the plot loads.

The hook merges these:
- the overview outside the detail window and the detail inside (`history_window.js` `_drawWindowData`);
- live backfill in front of the buffer (`live.js` prepend);
- the band rows of the overview and the detail (`bands.js`).

Every drawn line passes through `_drawnData(idx)` (`setpoints.js`), including the live flush and `_targetSeriesPatch`. It applies the setpoint hold (`_heldTarget`, `_pinToWindow`). The hook object is a spread of mixins in `echarts_chart.js`, where later keys win.

## Goals / Non-Goals

**Goals:**
- Gaps come from facts recorded when recording stops (spans). The heuristic serves only span-less, old sessions.
- Break placement happens **once, on the data as drawn**, after every merge, so seams between loaded parts can neither erase nor invent a break.
- No change to how readings are written, stored or aggregated.

**Non-Goals:**
- Making `History.window/4` gap-aware. It stays a pure reading query.
- Any visual treatment of a gap beyond the break.
- Reordering out-of-order live readings in general. It is today's behaviour; the break pass only skips pairs whose times don't increase.
- Closing the open spans of sessions archived after a server kill. The read-side staleness rule already ends them at `alive_until`, which gives the same plots.

## Decisions

### 1. A per-session `RecordingTracker`, the last child of `NodeServices`

The tracker is a new GenServer, not part of `NodeDBWriter`. The writer is an at-least-once batching machine with its own stop budget, while span bookkeeping is tiny, ordered and must not be dropped.

As the last child under `rest_for_one`, a tracker crash restarts only the tracker, and on shutdown the tracker stops first. A crash of a sibling (`NodeValues`, `PlotCache`, `NodeDBWriter`) stops the tracker with `:shutdown`, a clean exit: it closes the span as `stopped` and a new one opens with the next value update. Adoption applies only to a crash of the tracker itself.

**Init.** The tracker traps exits. In `handle_continue` it:
1. Subscribes to `"state_change"` and `"secop_conn_state"` for its node id (`"host:port"`, formatted through `Topics`).
2. Takes a snapshot of the node's state with its own `Registry.lookup(SecantClient.Registry.NodeStatem, node_id)` and `get_state` call, with a timeout. `NodeManager.fetch_node_state/1` is private; this is the same few lines. A failed or timed-out snapshot is retried on the next beat.
3. Monitors the statem pid. On `:DOWN`, and on any later state report while it holds no monitor, it looks the pid up and monitors it again.
4. Reads its session's left-open span. **No span is opened before that read succeeds**; a failed read is retried on the next beat.
   - If the span's `alive_until` is under 45 s old and recording is possible, it is **adopted**: the tracker carries on upserting that row's id.
   - Otherwise it is closed at `alive_until` as `:interrupted`. The close is queued ahead of any new open.

**When recording is possible.** The tracker keeps the last known `state`, `active` and `uuid` of its node, from:
- the init snapshot;
- `state_change` reports (all three);
- `conn_state` reports (`active` only).

Recording is possible while `state == :initialized`, `active == true` and `uuid ==` the session uuid. Each time that becomes true, the tracker **arms**. The first `value_update` after arming opens the span at that moment. The client's parser can broadcast the first values of an activation before the statem broadcasts `conn_state true`, so the tracker remembers the time of the latest `value_update`. If one arrived less than 2 s (wall time) before arming, on the current connection (after the latest `:initialized` report) and after the last close, the span opens at once, at that update's time. An update from an old connection therefore never reopens a span. Arming happens:
- on a reconnect's `:initialized` report;
- on a reactivation's `conn_state true`, which comes with no `:initialized` report;
- on a late activation after the services started;
- on the init snapshot, which opens the span at once instead of arming: the writer may already have stored the activation values from `NodeValues` before the tracker started, and a change-only node may send nothing more;
- after a suspend close.

Waiting for a value update matters on a reconnect. `active` is stale there, and the client offers no other confirmation for the current connection. A direct `read` reply also arrives as a `value_update` and can open an armed span. That is accepted: the node is answering on this connection.

The tracker subscribes to the node's `value_update` topic for its whole life, so there is no subscribe race. Handling each update is one match on the tracker's status.

**Closing** happens on a transition out of "possible":
- `:disconnected`: a report leaves `:initialized`, or the statem's `:DOWN` arrives;
- `:deactivated`: `active` turns false;
- `:stopped`: a report arrives under another uuid (a changed description; `NodeManager` stops these services right after), or `terminate/2` runs.

`terminate/2` first runs the clock check. On a clean exit (`:normal`, `:shutdown`, `{:shutdown, _}`) with a span open in state, it:
1. casts `PlotCache.recording(node_id, :stopped, now)`. `PlotCache` is still running on a normal stop, because the tracker is the last child and stops first. When `PlotCache` is the sibling that crashed (no Registry entry), the tracker broadcasts `{:recording, :stopped, now}` on the `plot_data` topic itself. Its buffered readings died with it, so there is nothing to keep in order;
2. queues `:stopped`;
3. drains the pending queue, the write in flight first, within a 5 s budget, and kills a write still in flight at the deadline (`Task.shutdown(task, :brutal_kill)`). The child spec's `shutdown` is 8 s.

On any other exit reason (a crash) it leaves the span open, so the restarted tracker can adopt it. A failed drain is logged; the read-side staleness rule then ends the span at `alive_until`.

### 2. Suspend check before everything, from wall vs monotonic time

Every message the tracker handles (beat, state report, value update, `:DOWN`, terminate) first runs `check_clock/1`.

- **The comparison.** It compares the wall-clock time (`System.os_time`) and the monotonic time (`System.monotonic_time`) elapsed since the previous check. The pair of readings is taken anew at every check, so one suspend is detected exactly once.
- **On a suspend.** If wall − monotonic exceeds 30 s, the host was suspended (or the clock stepped forward). The open span is closed at its last `alive_until` as `:interrupted`. Only then is the message itself handled. If recording is still possible, the tracker re-arms, so the next value update opens a new span.
- **Why it works.** ERTS's monotonic clock on Linux doesn't advance during a suspend, while the OS wall clock does; a stalled BEAM advances both equally. Checked on the dev machine: `erlang:system_info(os_monotonic_time_source)` reports `CLOCK_MONOTONIC`. Task 2.2 records this in the moduledoc. On a build whose monotonic clock counts suspended time, the check would never fire; that limitation is documented and was rejected as a design target.

The heartbeat is a `Process.send_after` every 10 s that sets `alive_until = DateTime.utc_now()` (OS time).

### 3. Span writes: whole-row upserts, one in flight, a closed row stays closed

Each span has a tracker-generated uuid, or the adopted row's id. Every change is one upsert of the full row by id, through the Ash create action `:record`:
- `upsert? true`, with `upsert_fields [:alive_until, :ended_at, :end_reason]`;
- `upsert_condition expr(is_nil(ended_at))`, so a late heartbeat can never reopen or alter a closed span.

**The pending queue.**
- Changes go into an ordered pending queue; heartbeats collapse per span id.
- Writes run in a linked `Task.async` task, one at a time, so a hung database never delays a beat or a clock check. The tracker traps exits and handles the task's `EXIT`. A crashed tracker takes its write with it, so a write from an old tracker can't land after a new one has read the open span.
- An open that hits the one-open-span index is not dropped. The tracker re-reads the session's open span and treats it like the left-open span at init. If it adopts that row, pending changes under the rejected id are rewritten to the adopted id. If it closes that row, it opens again.
- `:record` sets `return_skipped_upsert?`, so a heartbeat for a row that is already closed isn't an error.
- Transient errors keep the queue and retry on the next beat. Any other permanent error (a foreign key, say) drops that change and logs it.
- The error rules come from `NodeDBWriter.transient?/1`, which moves into a small shared module (`SecantService.DBErrors`). It is not copied.

**Durability** is per tracker lifetime (spec). Pending changes lost with a crashed tracker show up as a gap from the last written `alive_until`, unless the restart adopts the span.

### 4. The server sends gap intervals; the hook places the breaks

Breaks placed by the server per loaded window fail at the seams. A detail window inside a gap has no points and would erase the overview's break, and a live backfill ending at a gap would join the buffer. So the breaks are computed in the hook, on the merged data, from intervals the server sends.

**Server side: `SecantService.PlotDB.Gaps`.**

`for_session(session_uuid, from_ms | nil, to_ms | nil)` returns `{:spans, [[g0, g1 | nil]]}` or `:no_spans`, in **one query** per load. The query reads:
- the session's spans overlapping the window;
- the last span ending before the window and the first starting after it, so a window inside a gap knows both of its ends;
- whether any span exists.

The rules:
- `nil` bounds mean the session's first span to now. Time before the first span is no gap (spec).
- An open span with a stale `alive_until` (over 45 s) ends there; an alive open span ends now.
- After the last span, the gap has `g1 = nil` (no later span).
- The caller drops gaps shorter than `max(2 s, the load's bucket_ms)` (`Gaps.drop_short/2`), since `for_session/3` doesn't know the bucket. The hook could never break them, and the finer replies of a zoom bring them back. This bounds the payload for a node that flaps.

`Builders.hold_from/4` stays as it is. A setpoint pinned at a window start inside a gap is a point inside the gap: the hook doesn't draw it, and uses its value for the resume at `g1` (see below). That also gives a live plot opened during an outage the value it needs when recording resumes.

For span-less sessions, the first load and the overview reply also send `pollinterval_ms` per eligible series: lines whose parameter's **name** is `value`. The series name won't do, because a parameter plotted on its own is always series `"value"`.
- `pollinterval_ms` is the module's last reading of the session for its parameter named `pollinterval`, read by one query. The app has no other notion of a poll interval; it goes by that parameter name alone.
- The one value applies to the whole plot.
- Sessions with spans get no heuristic. A live plot's first load does get `_gaps` like any other load, but no `fallback`, since every session started after the deploy has spans.

**What is sent.** Only number-line plots get gaps: those gated on `Scalar.supported_type?` of the plot's value, i.e. `TimePlot`'s `Scalar` build.
- The first load puts `_gaps: %{gaps: [[g0, g1]], fallback: %{index => pollinterval_ms}}` on the option.
- The `"fetch-chart-window"`, `"fetch-chart-overview"` and `"fetch-chart-range"` replies carry `gaps` for their window. The range reply also gains `bucket_ms`.
- Other plot types get nothing, and the hook leaves them alone.

**Hook side: `assets/js/charts/gaps.js`.** It is spread **after** `Setpoints` in `echarts_chart.js`, and its `_drawnData` wraps the setpoint one: breaks first, then `_heldTarget`/`_pinToWindow`.

*Gap state.* The hook keeps every gap it has been told about for the page's lifetime:
- from the option (`echarts-data-<id>` destructures `_gaps` out of it, so it never reaches ECharts);
- from every window, overview and range reply;
- from the live transitions.

The drawn gap list is their **union**, with overlapping or equal intervals coalesced. Gaps are kept whole, never clipped at a seam. A gap a coarse reply left out is still known from a finer one, and no reply can erase a gap.

An open gap (`g1 = nil`) is ended by:
- a live `close` sent later by the server (`at` is later than its `g0`);
- or any reply that has the same `g0` with a finite `g1`.

A live `close` ends the latest open gap whose `g0` is at or before its `ms`. One that arrives before that gap is known is kept and applied once it is.

`gap-chart-<id>` maps `:stopped` to `{open: ms, at}` and `:resumed` to `{close: ms, at}`. In this hook, "open" and "close" refer to gaps, not spans.

*`_breakAt(data, gaps, { held, minMsAt })`.* It walks the points and gaps once, skipping pairs with `b.t ≤ a.t` (live arrival order).
- `minMsAt(t)` gives the bucket width of the part of the plot at `t`:
  - the detail's resolution inside the detail window;
  - the overview's coarsest resolution (`_resolution.bucket_ms`) outside it;
  - for live, the `bucket_ms` of the retained prepended range at `t`;
  - 0 elsewhere.

  It is evaluated per gap: a gap uses the finest width among the parts it overlaps, so a gap reaching into the detail window is judged at the detail's resolution.
- **Lines other than setpoints.** For each gap, take the consecutive pair `(a, b)` whose open interval overlaps it most; ties go to the earliest pair. Break only if that overlap is ≥ `max(2000, w)`, where `w` is the finest width among the parts the gap overlaps, so readings that continue through a recorded gap stay joined. Insert `[x, a.v]` if `x > a.t`, then `[x, null]`, where `x = clamp(g0, a.t, b.t)`. A pair breaks at most once, at its earliest qualifying gap. A gap after the line's last point adds nothing: the line already ends at its last reading (spec).
- **Setpoints (held lines).** Every qualifying gap breaks. A gap qualifies if `g1 − g0 ≥ max(2000, w)`; an open gap always qualifies:
  - insert `[g0, v]`, `[g0, null]`, with `v` the value in force at `g0`;
  - points of the line inside `(g0, g1)` are not drawn (spec);
  - if `g1` is set and the line has no point at `g1`, insert `[g1, v']`, with `v'` the value in force at `g1`, which counts readings inside the gap. It becomes the next `a`.

  A gap with `g1 = nil` after the last point ends the line. `_heldTarget` already turns a trailing `null` into `[end, null]`, and `_pinToWindow` repeats a `null` at the zoom edges.
- **Fallback.** For series listed in `fallback`, `_breakAt` first derives gaps from the line as drawn. A spacing `b.t − a.t > 5 × max(pollinterval_ms, minMsAt(a.t))` and `≥ 60_000` becomes a gap `(a.t, b.t)`, which then goes through the rules above. Judging the merged line avoids the seam problem.
- **Bands.** The break times of a band's mean line are computed once. `_bandData(src, which)` inserts `[t, null]` at those times where the band has rows on both sides, and keeps its existing overview/detail segment breaks. The band's fill ends at its last row before the gap, which is close to the mean line's end. The server sends no null rows; `_bandRowsOf` and the tooltip are unchanged.
- **Sampling.** One helper decides `sampling`: `"none"` while the series has a band or its drawn data contains a `null`, `"lttb"` otherwise. Both `_dataPatch` (initial render, rebuilds, live flush) and `_seriesPatch`, which today sets `"lttb"` for band-capable lines, use it. ECharts 6.1's LTTB keeps only the first NaN of a frame, so two nearby breaks could lose one.
- **Testable core.** `_breakAt` and the gap-set merging are pure functions exported from `gaps.js`, tested with `node --test`. That adds no dependency.

**Rejected alternative: breaks inside each server window** (the first draft). It needed null band rows, which `_bandRowsOf` can't place by time, and it broke at the seams of `_drawWindowData` and the live prepend. The issue preferred the server so that the CSV and NeXus exports would show the same gaps, and those exports are out of scope.

### 5. Live: gaps travel with the readings, in order

The tracker casts `PlotCache.recording(node_id, :stopped, ms)` on every close (`:disconnected`, `:deactivated`, a suspend, or a clean `:stopped` in `terminate/2`), after its clock check; a suspend's stop time is the last beat. It casts `(:resumed, ms)` on each open. `DashboardLive` keeps the chart on `node_services_stopped`, and reloads on `node_services_ready` only when the uuid changed, so a same-session services restart needs the live break too.

`PlotCache` publishes its buffered batch first, then `{:recording, kind, ms}` on the same `plot_data` topic. The ordering promise is `PlotCache`'s publication order. Readings still in flight between the client and `PlotCache` are no different from today.

`DashboardLive` routes the message like a reading: `send_update(HistoryDB, recording: {kind, ms})` for the selected module's plot. `HistoryDB` pushes `gap-chart-<id>`, with `{open: ms, at}` for `:stopped` or `{close: ms, at}` for `:resumed`, where `at` is the server time at which the message was sent. It does so only for plots whose option carried `_gaps` (number-line plots); other plots ignore the message.
- Recording events go into their own assign while the plot loads or rebuilds, apart from the `value_update` drop path. They are pushed after the load.
- The hook records the transition in the gap state and redraws. A `close` ends the latest open gap whose `g0` is at or before its `ms`. A `close` with no such gap is kept until one is known (Decision 4).

Placement happens at draw time, so a late `stopped` (a suspend noticed after new readings were drawn) still breaks in the right place, and the new readings stay after it.

### Database migration

`mix ash.codegen add_recording_spans` runs after the resource declares its indexes. It creates the table `recording_spans`:

| column | type | notes |
| --- | --- | --- |
| `id` | `uuid` | primary key, generated by the tracker |
| `sec_node_uuid` | `uuid` | foreign key to `sec_nodes.uuid`, `on_delete: :delete_all`, not null |
| `started_at` | `utc_datetime_usec` | not null |
| `alive_until` | `utc_datetime_usec` | not null |
| `ended_at` | `utc_datetime_usec` | null while open |
| `end_reason` | `text` | `disconnected`, `deactivated`, `stopped` or `interrupted`; null while open |

- **Indexes:** `(sec_node_uuid, started_at)`, and a partial unique index on `sec_node_uuid WHERE ended_at IS NULL`.
- **Kind of table:** ordinary, with about one row per connect cycle.
- **Existing hypertable data:** untouched. No column, index, aggregate or policy of `readings` changes. Sessions recorded before the deploy have no spans and use the fallback; every session started after the deploy has spans from its start.
- **Rollback:** revert the code and roll back the migration, which drops the table.

### Query count and payload on a long recording

The example is a 30-day session of 1 Hz readings with one suspend a day (about 30 gaps), in a Drivable plot with two lines.

- **First historical load:** today's queries plus **1 spans query per plot** (an indexed scan of about 30 rows). A span-less session adds the `pollinterval` query for its value line, **+2** in all.
- **Zoom, overview reload, range widening:** +1 each (+2 for the overview of a span-less session).
- **Live updates:** no extra query; one message per transition.
- **Payload:** a gap is a pair of numbers, sent once per reply. 30 gaps are about 1 kB of JSON, and gaps finer than a load's bucket are left out. The hook adds at most 3 points per gap per line.
- **Writes:** 1 span upsert per node every 10 s.

## Risks / Trade-offs

- [A node sends no value update after activation] → No span opens, so the time shows as a gap, which is truthful: nothing was recorded.
- [The wall clock steps forward by more than 30 s (an NTP correction)] → One recorded gap, at most the step long. Steps backwards are clamped: `alive_until` never decreases.
- [The tracker crashes during a DB outage] → Its pending changes are lost. Adoption on restart covers short outages; longer ones show a gap from the last written heartbeat.
- [A plot loads right as the database returns from an outage of more than 45 s] → A stale-span gap can show until the pending heartbeat lands seconds later. The next load is correct.
- [A node clock is off by more than a gap] → Placement is best effort (spec), and a reading is never dropped.
- [A sibling crashes while the database hangs for more than 5 s] → The `:stopped` close is killed at the drain deadline, and the restarted tracker may adopt the still-open span, so that restart shows no gap. This is rare and accepted.
- [Live range bookkeeping] → The hook keeps a list of the prepended ranges, each `{from, to, bucket_ms}`, trimmed with the buffers, for `minMsAt`.
- [The fallback marks false gaps for a node that sends `value` only on change] → It is limited to old sessions and to parameters named `value` with a `pollinterval`, with a threshold of 5× and at least a minute.
- [A change-only parameter plotted on its own (`ramp`) is drawn again only from its next reading after a gap] → Accepted (spec). Today's joining line is no more truthful.
- [The new child changes the supervision tree] → Hot reload won't add it. Ask the user for a dev-server restart, and never boot the app against the dev DB from a task.

## Migration Plan

1. The deploy runs the migration at release start (`Release.migrate`). Every node's services start with the tracker, as new sessions.
2. Old sessions have no spans and use the fallback.
3. Rollback: see Database migration.
