# Design

## Context

The gap pipeline from #184 and #185 works like this:
- **Spans:** `RecordingTracker` writes spans, closing each with an `end_reason` (see its moduledoc):
  - `disconnected`;
  - `deactivated`;
  - `stopped` (services stopping, or a node replaced by another session);
  - `interrupted` (a host suspend, or a span found left open after a kill or crash).
- **Gaps:** `PlotDB.Gaps.gaps/4` turns spans into gaps `[g0, g1 | nil]`. It keeps the running maximum of the span ends, and filters with `overlaps?/3`, which matches two-element gaps. The plot gets them as `_gaps` on the option and `gaps` on replies.
- **Live events:** the tracker calls `PlotCache.recording(node_id, :stopped | :resumed, ms)`, which broadcasts `{:recording, kind, ms}`. `DashboardLive.handle_info` forwards that to `HistoryDB.update`, which pushes `gap-chart-<id>` `{kind: "open" | "close", ms, at}`. The tests are in `dashboard_live_test.exs`.
- **Hook (`gaps.mjs`):**
  - `mergeGaps` merges the gap sets and live events into `_gapList()`.
  - `_broken` places line breaks: `breakLine` for most lines (a pair breaks once, at its first qualifying gap), `breakHeld` for setpoints, and `spacingGaps` for the fallback.
  - `_elementLine` breaks Lines-mode lines.
  - `clipRowEnds` ends heatmap rows; it stops at the first qualifying gap per row.
- **Two patch paths:**
  - Historical plots patch through `_seriesPatch()`.
  - Live plots flush in `live.js` `_flushBuffer`. It calls `_chartSeriesData().map(_dataPatch)` directly, and only when `_dataDirty`. On idle ticks it moves only the time axis and the setpoints.
- **Hover:**
  - ECharts' axis tooltip snaps a time axis to the nearest reading (`axisPointer/modelHelper.js`, `axisTrigger.js`). It is hidden when the nearest points are break nulls, which is the case over a gap.
  - The heatmap has its own readout: a `<div>` driven by `zr` `mousemove`, `convertFromPixel` and `_heatCellAt`, bound for every chart in `_bindHeatTooltip`.
- **Zoom:** number plots zoom with `filterMode: "filter"`. Heatmaps and their Lines mode don't filter (`keep_outside`), so the heatmap's `renderItem` sees the whole buffer.

## Goals / Non-Goals

**Goals:**
- Regions and hover descriptions as in the spec, decided by the same rules that break the lines and end the rows, on both patch paths.
- No change to how anything is broken or drawn today, and no change to the tooltip outside regions.

**Non-Goals:**
- Changing which gaps break a line.
- Per-series regions.
- Extending a time axis to show an open gap. A history plot's axis ends at its data, and so does the live "All" range: an open gap after the last reading shows only as far as the axis reaches, which may be nothing.

## Decisions

### 1. Reasons travel as a third gap element

**Server.**
- `Gaps.gaps/4` selects `end_reason` too, and carries it with the span that sets the running maximum end. The gap after it gets that span's reason as a string.
- A span counted as ending at its stale `alive_until` gives `"interrupted"`: it was left open by a stop the tracker didn't see, the same case the tracker itself closes as `interrupted`.
- `overlaps?/3` matches `[g0, g1 | _]`.

Gaps are `[g0, g1]` when the reason is unknown, and `[g0, g1, reason]` otherwise. Hook code that reads only `g[0]` and `g[1]` keeps working, and so do the JS tests. Elixir tests whose spans close with a reason now get three-element gaps and are updated (task 1.1).

**Hook (`mergeGaps`).** Today every gap is rebuilt as two elements. Each of these places must keep the third:
- where it reads the sets (`([g0, g1])`);
- the live "open" push (`[ev.ms, null]` gets `ev.reason`);
- where a live close rewrites the gap (`gaps[best] = [...]` must carry `gaps[best][2]`);
- the same-start filter, which drops an open gap for a finite one: the finite gap's reason wins, else the open one's moves over;
- the join: `last[2] = last[2] ?? g[2]` when it overlaps, and `out.push` copying `g[2]` when it doesn't.

The rules:
- A gap keeps its reason.
- Joined gaps take the reason of the earliest gap that has one.
- Of gaps with the same start, a finite one wins over an open one, as today, and so does its reason when it has one.
- A live "close" keeps the open gap's reason.

**Live events.**
- `PlotCache.recording/4` takes `reason` (default nil), and the message becomes `{:recording, kind, ms, reason}`.
- The tracker passes its close reason: `close`'s notify passes the reason it closes the span with (from `close_reason/1`, or `:interrupted` on a suspend), `terminate` passes `:stopped`, and `:resumed` passes `nil`.
- `DashboardLive.handle_info` and `HistoryDB.update` pass it on; the "open" event gets `reason`.
- The compiler doesn't catch stale `receive` / `assert_receive` patterns, so tasks grep for `{:recording,` in `lib` and `test`.

### 2. Which gaps are marked: reported by the functions that break

Each function that breaks also reports the gaps behind its breaks, in an optional `used` Set:
- **`breakLine`:** every gap whose best pair qualifies (overlap ≥ `max(2 s, width)`), whether or not it placed that pair's break. Two qualifying gaps between the same readings are both marked.
- **`breakHeld`:** the gaps it ended and resumed the line at (only where a value was in force), not the bare threshold filter.
- **`clipRowEnds`:** for each row, every gap that ends it or qualifies inside its original hold, not just the first.

The hook adds cases at the ends of the buffered data. Here "reading" means a real reading in the `_seriesData` buffers, not a point added for drawing, such as `_heldTarget`'s hold to now or a break's hold point.
- **No reading after it yet:** a gap whose end is after the last reading, which always includes an open gap (end Infinity). Comparing the end, not the start, holds when node clock times sit just past a server-stamped `g0`. This rule keeps a just-closed region shown until the next reading arrives.
- **No reading before it:** a gap whose start is before the first reading. A live fixed range trims the last reading before an outage once it leaves the window, and a live plot opened mid-outage never had one. Without this rule the region would vanish while the gap is still on screen. On history plots such a gap lies left of the axis and is clipped.
- **A plot with no readings** marks every gap.

The edge rules use the readings of all of a plot's lines together. On a live module plot, the trim keeps the setpoint's reading in force before the window, so "no reading before it" doesn't fire there. `breakHeld` reports that gap instead, because the setpoint is in force across it. A fake-hook test pins this.
- **Fallback gaps are excluded:** `_broken` passes `used` only for gaps from `_gapList()`, never for `spacingGaps`.

The marked list is `_gapList()` (already in time order) filtered by the set, so rendering and the binary search in `gapAt` use the same time-ordered array.

The reset, the collection and the edge rules are `Gaps` methods in `gaps.mjs`, called from `_chartSeriesData()`, so fake-hook node tests can load them: `echarts_chart.js` and `common.js` can't load under `node --test`.

**Where.** Both patch paths call `_chartSeriesData()`. It resets `this._marked` and collects into it:
- `_broken` and `_elementLine` pass it as `used`;
- for a heatmap, it runs `clipRowEnds` once over the buffer's rows, with `used`. The heatmap's `renderItem` sees the whole buffer, because nothing is filtered (`keep_outside`), so this gives the same rows. Both use one helper, `_heatRows(times, live)`, for the `held` ends.
- Envelope bands break at their line's breaks, so they need nothing more.
- Legend-hidden lines are still patched, so they count; the spec says so.

### 3. The region: marks on one unnamed, silent helper series

`_composeOption` appends, while `_gapsOn`, one line series:
- `id: "gap-regions"`, no `name` (so no legend entry), `data: []`;
- `silent: true`, `xAxisIndex` 0, `yAxisIndex` 0, `animation: false`.

The helper is not in `_seriesMap`. Its patch is appended by `id` to every series patch, on both paths:
- **`markArea.data`:** `[[{xAxis: g0}, {xAxis: g1 ?? Infinity}]]` per marked gap. `Infinity` clamps to the grid's right edge, as verified in the council's render test, so an open region follows the moving live axis without a per-tick patch.
- **`markLine.data`:** a vertical line at each start and at each finite end.

Layering and style:
- **z-order:** `markArea.z: 0` and `markLine.z: 1`, set explicitly, because a series' `z` doesn't reach its marks: their defaults are 1 and 5, which would draw the edges over the data. Lines (z 2–3) and the heatmap draw on top. Envelope areas also sit at z 1: they draw above the region's fill, with the dashed edges over them, which is harmless.
- **Blur:** `emphasis` and `blur` item and line styles equal to the normal ones, each setting `opacity` explicitly. Lines mode blurs other series on hover, and a blur style without `opacity` still fades the marks to 0.1.
- **Heatmap:** its `visualMap` is limited to its data series (`seriesIndex`).
- **Colours:** fill `--sc-muted` at 0.08 opacity (light) or 0.12 (dark); edges 1 px dashed `--sc-muted` at 0.6, no symbols, no labels. A theme switch rebuilds the option.

A plain number plot and a heatmap have no `_seriesMap`. The helper sits after the data series, so the positional patches of the data series are unchanged, and the series count read by `_symbols` simply includes it.

*Why marks on a helper, not a custom series:* custom series items are dropped by `filterMode: "filter"` when both ends lie outside the window. Mark components are not filtered and are clipped to the grid. The council's render test on ECharts 6.1 confirmed this, including a window wholly inside a gap.

### 4. Hover: one readout for every covered plot, from the pointer's pixel

The `zr` `mousemove` handler bound in `_bindHeatTooltip` runs for every chart. For a plot with marks:
1. It converts the pointer's x to time with `convertFromPixel({xAxisIndex: 0}, …)`, only inside the grid.
2. It looks the time up with `gapAt(t, regions)`, a binary search over the marked regions.
3. Inside a region, it shows `gapText(region, Date.now())` in the readout `<div>` and hides the ECharts tooltip. Outside, it hides the `<div>`, and the ECharts tooltip behaves as today.

For the heatmap, a drawn cell under the pointer wins over a region, and the spec says so. A row can overlap a marked gap only where a reading is stamped inside it, or where the last row reaches a short trailing gap it doesn't qualify to be ended by.

**Keeping it current.** The handler remembers the last pointer position. The hook repeats the lookup for that position after every `setOption`: a live flush (idle ticks included, where only the axis moves), a historical patch and `_rebuild`. That way a region that slid or closed under a resting pointer updates with the plot. `globalout` clears the position, the `<div>` and `.gap-hover`, and so does a rebuild that re-inits the chart.

The heatmap's `_heatCache` is cleared before each series patch. A range change that leaves no cells then can't answer the hover from cells that are no longer drawn.

`gapText` builds:
- `Not recorded`;
- the reason label from the spec table, or no line if unknown;
- `08:30:20 → 08:30:28 · 8 s`, or `since 08:30:20 · 3 min, ongoing`.

Times use `formatTime` and durations `formatBucket` (both in `common.js`). They are passed into `gapText`, not imported: `common.js` touches `window` at load, so importing it would break `node --test`. The readout is set as `textContent`, so no escaping is needed. `gapAt` and `gapText` are pure and node-tested.

To hide the tooltip, a class on the chart element (`.gap-hover`) hides `.echarts-tooltip` with `display: none !important` while the pointer is in a region. ECharts writes the tooltip's display inline, and the hook sets `tooltip.className`. CSS hides what ECharts re-shows on its own mousemove, so there is no fight over `hideTip`.

*Rejected:*
- **A tooltip formatter.** Over a gap the axis tooltip snaps to a reading outside the gap, or is hidden entirely. A formatter would also have to reproduce ECharts' default line tooltip.
- **markArea hover.** It isn't delivered while the tooltip triggers on the axis.

## Risks / Trade-offs

- **Two readouts in one place** (the ECharts tooltip and the `<div>`) → Only one is visible at a time, through the CSS class; task 3.1 checks the switch.
- **A just-closed gap stays marked until the next reading** → Intended: it is still a gap the plot shows. Once readings follow, the break rule takes over.
- **Open gaps are invisible on axes that end at the data** (history; live "All") → Accepted. Task 3.1 checks a fixed live range.
- **A live gap event arriving between a full option reload and the hook re-registering is lost** (pre-existing since #184) → The region appears with the next load or reply, which carries the gap.
- **The heatmap's mark pass repeats the row computation** → One linear pass, about 0.07 ms for 100k cells (measured in #185).

## Query count and payload

- **Queries:** none added. The spans query each covered plot load and reply already runs also selects `end_reason`.
- **Payload:** about 15 bytes per gap with a reason. A 30-day session with daily suspends has about 30 gaps, so about 0.5 kB per load.
- **Live:** the `gap-chart` open event gains one field. Idle live ticks send nothing new, because open regions end at `Infinity`.
- **Rendering:** about 30 `markArea` and 60 `markLine` items at most on such a view.

## Migration Plan

No database migration; hypertable data is untouched. Deploy with the app; roll back by reverting. Gaps without a reason show no reason line.

Archive `break-plots-at-recording-gaps`, then `break-array-plots-at-recording-gaps`, then this change: all three touch `plot-recording-gaps`. This change modifies the heatmap readout requirement added by the second.
