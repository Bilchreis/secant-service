# Proposal

## Why

#184 (`break-plots-at-recording-gaps`) made number lines break where nothing was recorded, but array plots still draw straight across an outage:
- **Heatmap:** each reading's row of cells holds until the next reading, so the last row before a disconnect or suspend is stretched over the whole hole. On a live plot, a row stays held "until now" while the node is gone.
- **Lines mode:** each element's line joins the readings on either side of the gap.

Both show data for time that has none, the problem #178 described for number lines.

## What Changes

- **Array plots get their session's gaps.** A plotted numeric array that is not a setpoint (`TimePlot`'s `ArrayHeatmap` build) gets `_gaps` on its option, like a number plot. The window, overview and live-range replies and the live `gap-chart` events then reach it through the paths #184 built, which key on `_gaps`.
- **Heatmap rows end at a gap.**
  - A row that would hold across a gap ends at the start of the earliest gap its hold overlaps by at least the width threshold a line breaks with; an open gap ends it at once.
  - A live plot's last row stops at an open gap instead of running on to now.
  - The hover readout shows nothing where a row was ended by a gap.
  - A row is never drawn longer than today.
- **Replies measure the lines a plot draws.** For a heatmap that means only `value`, not an undrawn `target` that would set the width gaps are judged at.
- **Lines mode breaks each element's line** like a value line, with a marker on a reading a break leaves on its own.

### Out of scope

- **Struct plots and the array fields inside them; setpoint arrays** (a Drivable struct's target array, a standalone `target` array).
- **Long arrays drawn as their latest reading only** (`ArrayLatest`), which have no time axis.
- **Enum plots.**
- **The fallback for sessions without spans.** Array plots of old sessions stay as they are.
- Any server-side change to spans, the tracker, the gap query or the live event path.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `plot-recording-gaps`: "Plots covered" now includes numeric array plots (heatmap and lines mode). New requirements say how a heatmap row and an array element line break.

The capability was introduced by the `break-plots-at-recording-gaps` change. That change is merged but not yet archived, so it must be archived first; this delta modifies its spec.

## Impact

- **Server:**
  - `SecantService.PlotDB.TimePlot`: one call to `Gaps.put/3` in the `ArrayHeatmap` build.
  - `PlotDB.Gaps.fallback/2`: limited to number lines.
  - `HistoryDB`: replies fetch only drawn lines.

  Each array plot load costs one more small indexed query, the spans of its session. A module's array reply costs one less, because its undrawn `target` is no longer fetched.
- **Chart hook:**
  - `assets/js/charts/arrays.js`: the heatmap row ends and the hover readout.
  - `assets/js/charts/echarts_chart.js`: the element lines in `_chartSeriesData`, and the gap branch of `_dataPatch` limited to line series while gaps exist.
  - `assets/js/charts/gaps.mjs`: a pure helper for the row ends, with node tests, and keeping the heatmap's cell buffer out of the line breaks.
- **Database:** no migration.
