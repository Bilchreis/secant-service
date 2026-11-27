# Proposal

## Why

When nothing was recorded for a while, the line plots join the last reading before the break to the first reading after it. The chart then seems to show data for a time that has none (issue #178). Examples: the host suspended, a node disconnected or deactivated, the node services restarted. A server restart already starts new sessions, each with its own plot; within the old session, the time after its end counts as a gap. A gap leaves no trace in `readings`, so the plot cannot tell it apart from a slow-changing value. The fix has to start where recording happens.

## What Changes

- **Record when each session was being recorded.** A new table of *recording spans*, one row per stretch of time in which a session's node was connected, active and its services were running. A span is opened when recording becomes possible and closed with a reason (`disconnected`, `deactivated`, `stopped`, `interrupted`). A heartbeat about every 10 s keeps an open span's `alive_until` current. A span opens with the first value update after the node is initialized, which confirms activation. Spans left open by a crash or a host suspend are closed at their last heartbeat; one left open by a server kill counts as ended there. A suspend is detected because the wall clock moved on while the BEAM's monotonic clock did not.
- **Break the number line plots at gaps.** A gap is time inside a session that no span covers. The server sends each plot its gap intervals with every load. The chart hook places the breaks (`null` points) on the data as drawn, after merging overview, zoom detail, live backfill and live readings, wherever a gap lies between two drawn points:
  - Setpoint (step) lines end at the gap start and resume at the gap end with the value in force.
  - The envelope band breaks too.
  - A break is drawn only where the line would otherwise bridge at least 2 s, and at least the plot's bucket width, of the gap.
- **Break open live plots.** When a node disconnects or is deactivated, the host is suspended, or the node's services stop, an open live chart ends its lines at that moment. When recording resumes, the setpoint lines resume.
- **Fallback for sessions recorded before this change** (they have no spans): a gap is assumed where consecutive readings of a module's `value` are much further apart than its poll interval. This applies only to parameters named `value`; setpoints never use it.
- **Database migration**: one new, small, ordinary table (`recording_spans`), deleted together with its session. Readings, aggregates and hypertables are untouched.

### Out of scope

- Enum, struct and array plots (state bands, struct rows, heatmaps), dashboard sparklines, the CSV export and the NeXus export. They keep today's behaviour. The gap data added here can serve them in later changes. The CSV export lists stored readings and keeps doing so; it gets no rows for gaps.
- Storing `error_update`s, or per-parameter "unavailable" intervals (issue item 2). A parameter the node could not read still looks continuous.
- Detecting a node that stays connected but stops sending updates. Spans follow the connection and the services only.
- Backfilling spans for old sessions. They rely on the fallback.
- Reordering readings that reach a live chart out of order, for example a node resending old timestamps on reconnect. Today's behaviour stays.
- Showing gaps any other way: shading, markers or a list of outages.

## Capabilities

### New Capabilities

- `recording-spans`: the record of when each session's node was being recorded, and how each stretch ended, kept correct across disconnects, stops, crashes and host suspends.
- `plot-recording-gaps`: how the number line plots (historical and live, raw, thinned and envelope) show time without recording as a break instead of a joining line.

### Modified Capabilities

None. `openspec/specs/` holds no archived capabilities yet. The in-flight `history-plot-envelopes` delta (change `add-plot-envelope-bands`) is not changed. Its band gains breaks through the new `plot-recording-gaps` requirements.

## Impact

- **Database**: migration adding `recording_spans`, with a foreign key to `sec_nodes` (`on_delete: :delete_all`) and an index on `(sec_node_uuid, started_at)`. New Ash resource in the `SecNodes` domain.
- **Node services**: a new per-node child of `SecantService.NodeServices` that owns the spans. It subscribes to `secant_client`'s `state_change` and `secop_conn_state` topics. Adding a child changes the supervision tree, so a running dev server needs a restart; hot reload is not enough.
- **Plot data**: a new `SecantService.PlotDB.Gaps` computes gap intervals per session, plus fallback gaps for old sessions. The first load (`TimePlot`'s number plots) and `HistoryDB`'s window, overview and range replies send them. `SecantService.PlotDB.History` itself is unchanged. Each load costs one more small indexed query per plot (two for an old session without spans).
- **Chart hook (JS)**: a new `gaps.js` places the breaks in `_drawnData`, for lines, and in `_bandData`, for bands. A new live event opens and closes gaps.
- **Live updates**: the tracker tells `PlotCache`, which publishes `{:recording, kind, ms}` after its buffered readings. `DashboardLive` passes it on to the plot component in order with the readings.
- **Shared error rules**: `NodeDBWriter`'s transient-error check moves into a small module that the tracker uses too.
