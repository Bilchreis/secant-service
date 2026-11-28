# Tasks

## 1. Server: gaps carry their reason

- [x] 1.1 In `PlotDB.Gaps` (design.md Decision 1):
  - select `end_reason`;
  - carry it with the span that sets the running maximum end;
  - emit `[g0, g1, reason]` when known, else `[g0, g1]`;
  - a stale open span gives `"interrupted"`;
  - `overlaps?/3` matches `[g0, g1 | _]`.

  Update the moduledoc and `@type gap`. Extend `test/secant_service/plot_db/gaps_test.exs`:
  - a suspend gap carries `"interrupted"`;
  - a disconnect gives `"disconnected"`;
  - a stale open span gives `"interrupted"`;
  - a span inside a longer one doesn't take over the reason;
  - a span without a reason gives a two-element gap.

  Update the existing assertions that now get three-element gaps:
  - in `gaps_test.exs`, the `for_param/3` test, "the plots" test and the `gaps/4` helper;
  - in `node_browser_live_test.exs`, the window and overview reply assertions near lines 127, 131 and 182 (assert `"disconnected"`).

  Verify both files pass.
- [x] 1.2 Pass the close reason from `RecordingTracker` through `PlotCache.recording/4` (`reason \\ nil`) as `{:recording, kind, ms, reason}`:
  - `:stopped` from `terminate`;
  - nil for `:resumed`.

  Update `PlotCache`, `DashboardLive.handle_info` and `HistoryDB.update` (the `gap-chart` "open" event gets `reason`), and the docs in `Topics`, `PlotCache` and the tracker moduledoc. Grep `{:recording,` in `lib` and `test` for stale patterns. In `dashboard_live_test.exs`, the pushed "open" event carries the reason. In `recording_tracker_test.exs`, a disconnect sends `:disconnected`. Verify those files and `plot_cache_test.exs` pass.

## 2. Chart hook

- [x] 2.1 In `assets/js/charts/gaps.mjs` (design.md Decisions 1, 2 and 4):
  - `mergeGaps` keeps the reason at every point named in Decision 1 (a join takes the earliest known; a non-overlapping gap keeps its own; same start: the finite gap's reason wins, else the open one's moves over; a live close keeps it; the "open" event's `reason`);
  - `breakLine`, `breakHeld` and `clipRowEnds` take an optional `used` Set and report as in Decision 2;
  - add `gapAt` and `gapText`. `gapText` takes the time and duration formatters as arguments, so `gaps.mjs` imports nothing from `common.js`.

  Add node tests to `gaps.test.mjs`:
  - the `mergeGaps` reason cases;
  - `breakLine`'s `used`: two qualifying gaps between the same readings are both reported, and a 30 s gap at a 15-minute width is not;
  - `breakHeld` reports nothing before the first setpoint reading;
  - `clipRowEnds` reports a second qualifying gap inside a row's hold;
  - `gapAt` at the edges of a region and between regions;
  - `gapText` for each reason, for an unknown reason, and for an ongoing gap.

  Verify `node --test assets/js/charts/gaps.test.mjs` passes, and that the existing tests are unchanged.
- [x] 2.2 Marking and the region (Decisions 2 and 3):
  - `Gaps` methods in `gaps.mjs`, called from `_chartSeriesData()`, reset and collect `_marked` (span gaps only), including the edge rules: no reading after the gap's end, no reading before its start, and no readings at all. Readings come from `_seriesData`, not drawn hold points. The marked list is `_gapList()` filtered by the set;
  - add `_heatRows`, shared with the heatmap's `renderItem`;
  - append the unnamed `gap-regions` helper in `_composeOption` while `_gapsOn`, outside `_seriesMap`, with explicit mark z, blur styles, and the heatmap's `visualMap.seriesIndex`;
  - append its patch by `id` on `_seriesPatch()` and in `live.js` `_flushBuffer`.

  Add fake-hook node tests:
  - a line, a setpoint and a too-short gap: exactly the qualifying gaps are marked;
  - a closed gap with no reading after it stays marked;
  - an open gap with a reading stamped just after its start stays marked;
  - a held setpoint's point at now doesn't unmark an open gap;
  - a gap starting before the first buffered reading is marked;
  - on a module plot whose setpoint keeps its pre-window reading, a gap reaching past the left edge is marked (through `breakHeld`);
  - the marked list is in time order when a later gap is found first;
  - a span-less fallback break marks nothing.

  Verify with `node --test` and `mix assets.build`.
- [x] 2.3 The gap readout (Decision 4):
  - in the `zr` mousemove handler, look up `gapAt` from the pointer's time inside the grid;
  - show `gapText` in the readout `<div>`;
  - toggle the `.gap-hover` class that hides the ECharts tooltip (`display: none !important`; `tooltip.className` set by the hook);
  - for the heatmap, a cell under the pointer still wins, and `_heatCache` is cleared before each series patch;
  - remember the last pointer position and repeat the lookup after every `setOption`, idle live ticks included; clear it, the `<div>` and the class on `globalout` and on a re-init.

  Verify with `mix assets.build`; behaviour is checked in 3.1.

## 3. Checks

- [x] 3.1 On the dev server (the user allows starting and stopping it; stop it afterwards if it wasn't running), stop the sim massflow container for about 90 s, then start it again. Check that `sim_gas_analysis` `mass_spec` is in continuous mode afterwards, and set it back if not. Verify with screenshots and pointer moves (`run-app` skill), in the light and dark themes:
  - **Live module plot, fixed 10-minute range:**
    - a region appears at the disconnect;
    - it still reaches the right edge a minute later, with no readings coming in;
    - it ends with a dashed line at the reconnect;
    - with the pointer resting inside the region, the readout changes from "ongoing" to the end time at the reconnect;
    - with the pointer resting just right of the region's start during the outage, the readout stays correct as the axis moves with no readings coming in;
    - its edges are behind the lines.
  - **Hover:** inside the region the readout shows "Not recorded", "Node disconnected", the times and the duration, and the ECharts tooltip is hidden. Moving onto a reading brings back the usual tooltip, unchanged.
  - **History plot of the session:**
    - at "every reading" it shows the region, with bands off and on;
    - zoomed into the gap, it is shaded across the whole plot area;
    - zoomed out until the line bridges the gap, it shows none.
  - **Mass-spec plot:** the heatmap and Lines mode show the region, and the heatmap readout describes the gap.
- [x] 3.2 Run `mix precommit` and `node --test assets/js/charts/gaps.test.mjs` (precommit does not run the node tests), and fix everything they report. Verify that both exit 0.

## Workflow follow-up

- Archive `break-plots-at-recording-gaps`, then `break-array-plots-at-recording-gaps`, then this change: all three modify `plot-recording-gaps`, and this one modifies a requirement added by the second.
