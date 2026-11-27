# Tasks

## 1. Server

- [x] 1.1 In `TimePlot.build(ArrayHeatmap, ...)`, call `Gaps.put(plot, [value], gap_window(mode))` unless `value.setpoint?`. In `Gaps.fallback/2`, list only lines whose parameter is a number. Update the moduledocs and comments of `TimePlot`, `PlotDB.Gaps` and the `gaps.mjs` header that say "number-line plots" (design.md Decision 1). Extend `test/secant_service/plot_db/gaps_test.exs`:
  - a numeric array plot of a session with a gap carries `_gaps` with those intervals and an empty `fallback`, also in a session without spans;
  - a standalone `target` array and an `ArrayLatest` plot carry none.

  Verify the file passes.
- [x] 1.2 In `HistoryDB`'s window, overview and range handlers, fetch only the lines the plot draws, with `Map.get(plot, :lines)` (design.md Decision 2). Add a `node_browser_live_test.exs` case: a module with an array `value` of 10 readings and a number `target` of 5000 readings (so the target alone is thinned) answers a window fetch with `gaps` and an unthinned resolution. The case must fail without the filter. Verify that it and the existing HistoryDB tests pass.

## 2. Chart hook

- [x] 2.1 In `assets/js/charts/gaps.mjs`:
  - add `clipRowEnds` (design.md Decision 4);
  - keep `_broken` from touching an array plot's buffer;
  - use `"circle"` for lone markers when the symbol is `"none"` (Decisions 3 and 6).

  Add node tests to `gaps.test.mjs`:
  - the spectrum scenario;
  - readings stamped inside a gap (each row ends at its reading);
  - a short gap before a long one (the row ends at the long one);
  - a 30-second gap at a 15-minute width (no clipping);
  - readings 1 s apart through a closed 20 s recorded gap (no clipping);
  - a live last row and an open gap that started 1 s ago (clipped at once);
  - a historical last row whose gap starts after its current end (not lengthened);
  - no gaps (ends unchanged);
  - the `Gaps` mixin on a fake array hook: `_broken` leaves the cell buffer as is;
  - `_gapDataPatch` with symbol `"none"` and a lone reading gives a `"circle"` marker (`_lone` and `_dataPatchOf` stubbed on the fake hook).

  Verify that `node --test assets/js/charts/gaps.test.mjs` passes, including the existing tests.
- [x] 2.2 In `assets/js/charts/arrays.js` `_arrayHeat`, draw and cache the `clipRowEnds` ends while `_gapsOn` and the gap list is not empty. Verify with `mix assets.build`.
- [x] 2.3 In `assets/js/charts/echarts_chart.js`:
  - in `_dataPatch`, take the gap branch only for line series, and in an array plot only while the gap list is not empty; number plots keep their condition (Decision 3);
  - in `_chartSeriesData`'s `elem != null` branch, break element lines with `breakLine` under the same condition (Decision 6);
  - update the "number-line" comments listed in the design's Context.

  Put the "which patch" decision in a `gaps.mjs` method, so `node --test` can load it without `echarts_chart.js`. Test it on fake hooks with `_lone` and `_dataPatchOf` stubbed:
  - a span-less array plot in Lines mode with NaN elements gets the plain patch;
  - a span-less number line with fallback breaks still gets `sampling: "none"` and its marker.

  Verify with `mix assets.build` and `node --test`.

## 3. Checks

- [x] 3.1 On the dev server (the user allowed starting and stopping it; stop it afterwards if it wasn't running), stop the `abstraction_layer` container (`rock-it-abstraction_layer-1`) for a minute and start it again. First check that its `flow_calibration.value` array updates periodically; if not, use `nerves_sysinfo_node` `cpu_util.value`. Verify with screenshots (`run-app` skill):
  - the live heatmap's last row stops at the disconnect, with the "all" range too (design.md Decision 5), and rows resume after the reconnect;
  - the history heatmap has an empty gap, and the readout is empty there;
  - in Lines mode, every element line breaks;
  - a zoomed detail window inside the overview still shows the gap.
- [x] 3.2 Measure the performance cost of the gap features, of #184 and of this change, on long data. The user asked for this assessment.
  - The hook's per-redraw time for `_drawnData`/`breakLine` on a 20k-point line, `clipRowEnds` on a 100k-cell heatmap, and Lines mode with 100 element lines × 4000 points, each with and without gaps.
  - The draw time of a long line with breaks (`sampling: "none"`) against without (LTTB).
  - The extra queries per load, and the tracker's span writes per node.

  Record the numbers in the PR. Fix what regresses visibly in this change's code (the hook, the replies). Report anything in #184's tracker to the user rather than changing it here.
- [x] 3.3 Run `mix precommit` and `node --test assets/js/charts/gaps.test.mjs`, and fix everything they report. Verify that both exit 0.

## Workflow follow-up

- Archive `break-plots-at-recording-gaps` (merged in #184) before archiving this change: this delta modifies its `plot-recording-gaps` spec, which exists only once that change is archived.
