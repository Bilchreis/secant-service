# Design

## Context

The `break-plots-at-recording-gaps` change (#184) built the gap pipeline:
- spans recorded per session;
- `PlotDB.Gaps` intervals, sent with every load of a plot whose option carries `_gaps`;
- live `gap-chart-<id>` events, also sent only to plots with `_gaps`.

In the hook, `gaps.mjs` keeps the merged list (`_gapList()`) and the width a gap is judged at (`_gapWidth`). For number lines, `_drawnData` → `_broken` → `breakLine` places the breaks, and `_dataPatch` → `_gapDataPatch` sets sampling and the lone-reading markers. Both run for every series of a plot once `_gapsOn` is set.

Only `TimePlot`'s `Scalar` build calls `Gaps.put/3`. Several comments say "number-line plots" (`time_plot.ex`, `gaps.ex`, the `gaps.mjs` header, `historyDB.ex` around the recording push and the reply helpers, `echarts_chart.js` at the `_gaps` destructure). Array plots have two drawings:

- **Heatmap** (`arrays.js` `_arrayHeat`): a custom series painted onto one canvas from a buffer of flat cells `[t, index, value]`. With no `_seriesMap`, `_chartSeriesData` passes that buffer through `_drawnData`. For each reading `k` the renderer computes a row end, `ends[k] = times[k + 1]`. The last row ends at now on a live plot, or after one typical interval on a historical one. The hover readout (`_heatCellAt`) reads the cached ends.
- **Lines mode:** `_seriesMap` maps each drawn line to `{src, elem}`, and `_chartSeriesData` splits the cell buffer per element (`elem != null`), bypassing `_drawnData`. Element lines are composed with `symbol: "none"`. `_rebuild` always overwrites the first compose with `_seriesPatch()`, so only `_chartSeriesData` needs changing.

`TimePlot` draws an array plot's first line only. That is a module's `value`, or a parameter on its own, which can be a standalone `target` (a setpoint, held from the window start by `fetch_held_param_window`). `HistoryDB`'s window, overview and range handlers fetch every line of `PlotDB.lines/1` and report the coarsest resolution of them all, including lines the heatmap doesn't draw.

## Goals / Non-Goals

**Goals:**
- Heatmap rows and element lines of a numeric, non-setpoint array break at the same gaps and width threshold as its value line (element lines by the line rule itself, heatmap rows by the per-row rule of Decision 4). Zooming and live updates then behave as they do for number lines.
- No change to spans, the tracker, the gap query, the live event path or the database.

**Non-Goals:**
- Struct plots and their array fields; setpoint arrays (a standalone `target` or `_target_calibrated`); `ArrayLatest`.
- The fallback heuristic for sessions without spans, for arrays.

## Decisions

### 1. Non-setpoint array plots get `_gaps`

`TimePlot.build(ArrayHeatmap, [value | _], mode)` pipes the heatmap plot through `Gaps.put(plot, [value], gap_window(mode))` unless `value.setpoint?`.

`Gaps.fallback/2`, shared by `put/3` and the overview's `reply/4`, lists only lines whose parameter is a number (`Scalar.supported_type?`). The current heatmap series has no `name`, so it finds nothing today; the guard makes that explicit and keeps it true. No `put/3` option is needed.

The replies, the live push gate and `Gaps.reply/4` key on `_gaps` and need no change. A plot rebuilt as `ArrayLatest` has no `_gaps`.

### 2. Replies measure the lines a plot draws

The window, overview and range handlers in `HistoryDB` fetch only the lines the plot draws, when it has a `lines` map: `drawn = Map.get(plot, :lines)`, then `if drawn, do: Enum.filter(lines, &Map.has_key?(drawn, &1.param.name)), else: lines`.
- Number, enum and struct plots draw all of their lines, so nothing changes for them.
- A heatmap draws only `value`, so its reply resolution, and with it `_gapWidth`, comes from the drawn series and not from an undrawn `target`. That also drops a needless query for each such reply.
- `ArrayLatest` and not-plottable results have no `lines` and keep today's behaviour.

### 3. Gap breaks never touch a heatmap's cell buffer, and nothing changes without gaps

- `_broken(idx)` (`gaps.mjs`) returns the buffer unchanged while the plot is an array plot (`this._isArrayPlot()`). In heatmap mode the buffer is cells, not a line, and `breakLine` would insert phantom cells.
- `_dataPatch` (`echarts_chart.js`) takes the `_gapDataPatch` branch only for line series. In an array plot that means Lines mode (`this._arrayMode === "lines"`), and only while the gap list is not empty: arrays get no fallback, so an empty list means no breaks, and an old recording's reading between two NaN elements gets no new marker and keeps LTTB. A heatmap's custom series gets its patch as today. Number plots keep #184's condition unchanged: a span-less number plot has an empty gap list but fallback breaks, and needs the branch.

### 4. Heatmap rows: each row clipped by its own hold

New, pure, in `gaps.mjs`: `clipRowEnds(times, ends, gaps, { widthAt })` returns new ends.
- For each row `k` with hold `(times[k], ends[k])`, find the earliest gap that is open and starts before the hold ends, or whose overlap with the hold is at least `max(2 s, widthAt(g0, end(g)))`, with `end(g)` = Infinity for an open gap, as in `breakLine`. An open gap means recording stopped, so it cuts the live last row with the next flush, before 2 s of overlap have built up. Then `ends[k] = min(ends[k], max(times[k], g0))`.
- The rule is the same for every row, including the last one, whose hold runs to now on a live plot.
- It is linear: rows and gaps are both in time order, so one forward pass serves all rows.

This is per row, not `breakLine`'s best-overlap pair. Several readings stamped inside one gap must each stop at their own time, and a short gap that doesn't qualify must not hide a long one after it. Readings less than 2 s apart that continue through a closed recorded gap keep their rows, because each hold overlaps the gap by less than the threshold.

A row that begins inside a gap ends at its reading; the renderer's existing 1 px minimum still shows it as a thin line. A row is never longer than today.

In `renderItem`, the computed `ends` go through `clipRowEnds` when `_gapsOn` and the gap list is not empty, with `widthAt` from `_gapWidth`. The clipped ends are drawn and cached in `_heatCache`, so `_heatCellAt` returns nothing past a clipped end.

### 5. A gap change redraws through the existing paths

ECharts clones the option on every `setOption` and rebuilds the series data, so a heatmap re-runs `renderItem` whenever its series is patched, even with an unchanged data reference.
- Live plots: `_gapsChanged` sets `_dataDirty`, and the next flush patches the series.
- Historical plots: `_gapsChanged` patches the series at once.

Neither needs anything new. Task 3.1 checks it on a live plot with the "all" range, where no axis patch is sent. If the last row doesn't stop there, a one-time refresh of the heatmap series is added.

### 6. Element lines through `breakLine`, with visible lone readings

In `_chartSeriesData` (`echarts_chart.js`), the `elem != null` branch returns `breakLine(split[src][elem], this._gapList(), { widthAt }).data` while `_gapsOn` and the gap list is not empty. Struct plots never have `_gapsOn`, so their element lines stay as today.

`_gapDataPatch` uses `"circle"` for the markers of lone readings when the series' symbol is `"none"` or missing, because array lines have `symbol: "none"`.

## Risks / Trade-offs

- [`renderItem` runs on every redraw] → `clipRowEnds` is linear in readings plus gaps, next to a loop that already paints every cell.
- [Lines mode with a gap in view: every element line contains a null, so none is sampled (up to 100 lines × 4000 points)] → Measured in task 3.2; if it is visibly slow, element lines keep LTTB and a break that sampling drops is accepted.
- [A reading inside a gap draws as a 1 px row] → It is still visible, and matches "a gap never hides a reading" in spirit.
- [Arrays of sessions without spans keep joining across holes] → Accepted; see Non-Goals.

## Query count and payload

- **Each non-setpoint array plot load:** +1 query, the session's spans. This is the same indexed query a number plot runs: about 30 rows on a 30-day session with daily suspends.
- **Window, overview and range replies of a module's array plot:** one query fewer than today, because undrawn lines are no longer fetched.
- **Payload:** about 1 kB for 30 gaps; heatmap and line data are unchanged.
- **Database:** no change, so no effect on hypertable data.

## Migration Plan

Deploy with the app. Rollback means reverting the commit. Archive `break-plots-at-recording-gaps` before archiving this change, because this delta modifies its spec.
