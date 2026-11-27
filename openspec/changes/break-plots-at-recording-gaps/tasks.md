# Tasks

## 1. Recording spans: resource and migration

- [x] 1.1 Load the `ash-framework` skill. Add the `SecantService.SecNodes.RecordingSpan` resource:
  - table `recording_spans`, with the columns from design.md; `end_reason` is an atom attribute with `one_of` constraints, stored as `text` (no Postgres enum type);
  - `belongs_to :sec_node`, keyed by `sec_node_uuid`, with foreign key `on_delete: :delete_all`;
  - both indexes in `custom_indexes`;
  - the `:record` upsert action by id: `upsert_fields [:alive_until, :ended_at, :end_reason]`, `upsert_condition expr(is_nil(ended_at))`;
  - a read of a session's open span;
  - code interfaces on `SecantService.SecNodes`.

  Verify `mix compile --warnings-as-errors`.
- [x] 1.2 Run `mix ash.codegen add_recording_spans`. Verify that the migration creates only the new table and its two indexes, and touches no `readings` hypertable or aggregate. Verify that `MIX_ENV=test mix ecto.migrate` and a rollback both succeed.
- [x] 1.3 Test the resource in `test/secant_service/sec_nodes/recording_span_test.exs`:
  - an upsert twice by id updates the row in place;
  - an upsert of a closed span changes nothing;
  - a second open span for a session returns an error;
  - purging a trashed session deletes its spans.

  Verify the file passes.

## 2. Recording tracker

- [x] 2.1 Move `NodeDBWriter`'s `transient?/1` rules into `SecantService.DBErrors` and use it from the writer. Verify that the `NodeDBWriter` tests pass unchanged.
- [x] 2.2 Add `SecantService.RecordingTracker`, following design.md Decisions 1–3:
  - subscribe, then take a state snapshot (its own Registry lookup and `get_state`, retried), and monitor the statem, monitoring again when it holds no monitor;
  - read the left-open span before any open; adopt it by id or close it as `:interrupted`;
  - keep the node's last `state`/`active`/`uuid` from the snapshot, `state_change` and `conn_state`; arm each time recording becomes possible (reconnect, reactivation, late activation, after a suspend) and open at the next `value_update` (subscribed for the tracker's whole life), or at one less than 2 s (wall time) before arming on the current connection and after the last close; at init, open at once when the snapshot is active;
  - close as `:disconnected`, `:deactivated` or `:stopped`;
  - make `Topics.address/1` public (or add `Topics.node_address/1`) for matching reports;
  - run `check_clock/1` (wall vs monotonic since the previous check, over 30 s) before every message and in `terminate/2`;
  - beat every 10 s;
  - keep the ordered pending queue, written by one linked task at a time, with `DBErrors` deciding transient vs permanent;
  - `return_skipped_upsert?` on `:record`;
  - in `terminate/2`, on a clean exit only: cast `:stopped` to `PlotCache`, queue the close and drain within 5 s, killing a write still in flight (child `shutdown` 8 s); on a crash, leave the span open;
  - on a one-open-span conflict, adopt (rewriting pending changes to the adopted id) or close and reopen.

  The clocks and the interval are swappable through application config. Record the result of `erlang:system_info(os_monotonic_time_source)` in the moduledoc.
- [x] 2.3 Add the tracker as the last child of `SecantService.NodeServices` and document it in the moduledoc. Verify that the existing `NodeServices`/`NodeManager` tests pass. Tell the user that trying it needs a dev-server restart.
- [x] 2.4 Test `test/secant_service/recording_tracker_test.exs` against every `recording-spans` scenario. Use broadcasts in the real client order (`:initialized` with `active` still true on reconnect) and the swappable clocks. Cover:
  - open at once on start when the node is active, with no later value update (a change-only node);
  - a value update from before a reconnect not reopening a span;
  - reconnect then open at the first value update, and no value update giving no span;
  - deactivate then reactivate (only `conn_state true`, no `:initialized` report) reopening at the next value update, and the value update arriving just before `conn_state true` opening at once;
  - services starting while initialized but inactive, then activated;
  - disconnect;
  - statem `:DOWN` and a second crash after re-monitoring;
  - a new uuid, which closes as `:stopped`;
  - a clean stop that drains the queue, with no late heartbeat reopening the span, and a crash that leaves the span open for adoption;
  - an open that hits the one-open-span index (a stale row written meanwhile), resolved by adopt, with a queued close landing on the adopted row, or by close;
  - a sibling crash (`:shutdown`) closing as `stopped`, and a tracker crash leaving the span for adoption;
  - adopt (same id) versus close a left-open span, and an unreadable left-open span opening nothing until it can be read;
  - suspend (wall +10 min, monotonic +10 s) versus a 45 s stall (both clocks +45 s);
  - a disconnect right after resume, after which the next beat detects nothing;
  - a hung or failing upsert (injected) that delays no beat, then recovery with no gap.

  Use `start_supervised!` and no sleeps. Verify the file passes.

## 3. Gap intervals on the server

- [x] 3.1 Add `SecantService.PlotDB.Gaps.for_param/3` (the parameter's session) (design.md Decision 4): one query with the neighbouring spans, `nil` bounds, no gap before the first span, the 45 s staleness rule, `g1 = nil` after the last span; every gap is sent, the hook judges which it can draw. Add the `pollinterval_ms` lookup for span-less sessions in one query. Test in `test/secant_service/plot_db/gaps_test.exs`:
  - two spans with a gap between them;
  - a stale and an alive open span;
  - `:no_spans`;
  - a window entirely inside a gap, which still knows its `g1` (or `nil`);
  - a window before the first span, which has no gaps;
  - `nil` bounds;
  - a module with and without `pollinterval` (its last reading of the session).

  Verify the file passes.
- [x] 3.2 Send gaps with every load of a number-line plot (`TimePlot`'s `Scalar` path):
  - `_gaps` (`gaps`, `fallback`) on the option, including the live first load (which gets no `fallback`);
  - `gaps` on the `"fetch-chart-window"`, `"fetch-chart-overview"` and `"fetch-chart-range"` replies, plus `bucket_ms` on the range reply, and `fallback` on the overview of a span-less session.

  Assert in the plot_db and HistoryDB tests:
  - a session with a gap gets its intervals;
  - enum, struct and heatmap plots get none;
  - gap-free payloads are otherwise unchanged;
  - the query count is +1 per load, or +2 for the first load and the overview of a span-less session.

  Verify the tests pass.

## 4. Breaks in the chart hook

- [x] 4.1 Add `assets/js/charts/gaps.mjs` (`.mjs`, so `node --test` loads it as ESM), spread after `Setpoints` in `echarts_chart.js`, with its `_drawnData` wrapping the setpoint one (design.md Decision 4). It needs:
  - in `echarts-data-<id>`, `_gaps` destructured out of the option;
  - every gap kept for the page's lifetime, drawn as their union (coalesced, never clipped), an open gap ended by a later live `close` (server time `at`) or a reply with the same `g0`, and an early `close` kept until its gap is known;
  - `prepend-chart-data-<id>` reading `gaps` and `bucket_ms`;
  - `_breakAt` with the width of the finest part a gap overlaps (live ranges by their own `bucket_ms`), a pair breaking at its earliest qualifying gap, the max-overlap pair, the overlap threshold, the setpoint rule (every gap, nothing drawn inside, resume at `g1` with the value in force there), skipping pairs with `b.t ≤ a.t`, and the fallback evaluated on the merged line;
  - band breaks in `_bandData` at the mean line's break times;
  - one sampling helper (`"none"` with a band or a `null`), used by `_dataPatch` and `_seriesPatch`.

  Export `_breakAt` and the set merging as pure functions. Test them in `assets/js/charts/gaps.test.mjs` with `node --test`, against the `plot-recording-gaps` scenarios: a raw gap; one and two gaps on a held target; a setpoint reading inside a gap; continuous readings through a 20 s gap; a gap at a detail seam, kept whole; a short gap known only from the detail; a setpoint pinned at a window start inside a gap, resuming at `g1`; a live plot opened during an outage; a late live `stopped`; a live `close` after a reply's open trailing gap; the fallback. Import siblings with their `.js` extension so Node can load `gaps.js`. Add the `node --test` step to `.github/workflows/ci.yml` next to `mix test`. Verify that `node --test "assets/js/charts/*.test.mjs"` and `mix assets.build` pass.
- [ ] 4.2 Also check the drawing in the browser against the `plot-recording-gaps` scenarios. Seed sessions with spans and readings in the test DB, or use the user's dev server after asking (`run-app` skill). Cover:
  - raw, thinned and envelope parts, with the band breaking with its mean line;
  - a target unchanged across one gap and across two, and zoomed into a gap;
  - a detail window inside a gap, then zoomed out;
  - a gap straddling a detail edge;
  - a live range widened over a gap;
  - continuous readings through a 20 s recorded gap, which gives no break;
  - a node clock a few seconds behind;
  - two gaps a few points apart in a narrow chart, both still drawn;
  - an old span-less session with the fallback.

  Record the screenshots in the PR.

## 5. Live gaps

- [x] 5.1 Add `PlotCache.recording/3`: on a transition, publish the buffered batch, then `{:recording, kind, ms}`. Call it from the tracker on opens and on every close, including a clean `:stopped` in `terminate/2`, after its clock check. Test the order in `test/secant_service/plot_cache_test.exs` (buffered readings come before the recording message) and verify it passes.
- [x] 5.2 Pass the transition on to the chart:
  - `DashboardLive`: route `{:recording, kind, ms}` through `send_update(HistoryDB, recording: …)` for the selected module's plot;
  - `HistoryDB`: push `gap-chart-<id>` (`open`/`close` with the server time `at`), keeping events that arrive during a load or rebuild in their own assign and pushing them afterwards;
  - hook: record the transition in the gap state (a `close` ends the latest open gap at or before it, or is kept until one is known) and redraw;
  - only plots whose option carried `_gaps` get `gap-chart-<id>`;
  - when `PlotCache` is not running (it is the crashed sibling), the tracker broadcasts the stop on the `plot_data` topic itself.

  Add LiveView tests:
  - a recording message after a reading pushes the reading first, then `gap-chart-<id>`;
  - an event during a load is pushed after it;
  - an enum plot gets no `gap-chart-<id>`.

  Verify they pass.
- [x] 5.3 Update the `@moduledoc`s of `SecantService.PlotDB.Builders` (`hold_from/4` pins inside gaps on purpose: the hook hides those points and uses them for the resume), `SecantService.PlotCache`, `SecantService.Topics` (the new message) and `SecantService.NodeServices`. Verify by reading them.

## 6. Integration check

- [ ] 6.1 Run the migration on the dev DB, then, with the user's running dev server, after asking for the restart the new child needs, walk through the issue's acceptance, with the dashboard open:
  - stop the sim node for a minute, then start it again;
  - deactivate and reactivate a node;
  - stop and restart a node's services in the same session;
  - stop the server and start it again: the old session's history plot ends at the stop, and the dashboard shows a fresh plot for the new session;
  - suspend the host for a minute (`systemctl suspend`, done by the user).

  Check that the history plot (raw, thinned, envelope) and the live plot of `massflow_contr2.value` and its `target` break and resume correctly. Verify with screenshots (`run-app` skill).
- [x] 6.2 Run `mix precommit` and fix everything it reports. Verify that it exits 0.
