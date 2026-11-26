# Proposal

## Why

A thinned historical line plot of a long recording is hard to read. It keeps each bucket's first, last, lowest and highest reading, so a noisy signal turns into a solid block of vertical strokes, and the trend inside the noise is hidden. The continuous aggregates added in `add-reading-aggregates` already store min, max and mean per 1-minute and 1-hour bucket for numbers, array elements and depth-1 struct members. A plot can draw them as a mean line inside a shaded min–max band (an envelope), which shows the trend and the spread at the same time. The aggregates are cheap to read: about 10 ms for a scalar over 72 h, against a thinning pass over every reading today.

## What Changes

- Historical line plots get an **envelope mode**: per bucket, a shaded band from min to max and a line through the mean, read from the aggregates. It applies to:
  - number parameters (`double`, `int`, `scaled`), on their own or as a module's `value` (Readable, Drivable);
  - numeric array plots in "Lines" mode, one band per element.
- The plot toolbar gets an **envelope toggle**. It is on by default, except for array plots, where it is off because one band per element can bury the lines. The choice is remembered per browser, separately for array plots and for other plots, as the Heatmap/Lines choice is.
- **Fallback when zoomed in:** the envelope is drawn only while the window is split into buckets of 1 minute or more, the finest aggregate tier. When the window is narrow enough for finer buckets or for every reading, the plot draws exactly what it draws today, without a band.
- **Edges and the not-yet-aggregated tail:** only whole buckets inside the window that are materialized come from the aggregates. The partial bucket at each edge of the window, and everything after the aggregates' `materialized_until`, are drawn as today's line. So the newest minutes are always shown, and the time axis keeps its full extent. While the aggregates are still backfilling after a deploy, the whole window is drawn as today.
- The resolution label says what is shown: "min/mean/max · 15 min intervals" for an envelope, alongside today's "thinned · …" and "every reading".
- With the envelope on, the thinning query is not run for the aggregated part of a scalar or array window. On the bench, a 50-element array's 72 h window takes 0.3 s instead of 4.4 s, and a double's 14 ms instead of 41 ms. With the envelope off, plots load as today.

**Out of scope:**
- Live plots (`:live` mode). Their window is short and drawn from every reading.
- Enum plots, heatmaps, setpoints (a Drivable's `target`), Calibratable and Acquisition plots. They keep today's drawing.
- Struct plots, including their number members. They have member aggregates, but they would need the thinning pass anyway for their other members, and their series mapping is the most involved. They can follow in a separate change.
- Switching today's thinned line (envelope off) to read from the aggregates. That would speed up array and struct plots on its own and can follow as a separate change.
- Real-time aggregation of the tail, and any change to the aggregate views, their refresh policies or the `readings` hypertable.
- Applying a `scaled` parameter's scale. Plots draw stored values today, and the envelope does the same.

## Capabilities

### New Capabilities
- `history-plot-envelopes`: how historical line plots draw per-bucket min/max bands and mean lines from the reading aggregates, when they fall back to today's drawing, and how the envelope is toggled.

### Modified Capabilities

None. There are no specs in `openspec/specs/` yet. The `reading-aggregates` capability (still in the unarchived `add-reading-aggregates` change) is read as is; its requirements do not change.

## Impact

- **Code:**
  - `SecantService.PlotDB.History` gains an envelope read that combines `Aggregates.numbers/4` for the whole buckets in a window with today's thinning for its edges and tail.
  - The `:history_window` action on `Parameter` takes an `envelope` argument.
  - `SecantService.PlotDB` decides which parameters may carry an envelope and builds the envelope payloads.
  - `SecantServiceWeb.Components.HistoryDB` passes the toggle on window fetches and serves a new overview reload.
  - The `EChartsChart` hook in `assets/js/app.js` gets the toggle button, the band series, the tooltip, and the overview reload on toggle.
- **Database:** no migrations. Reads only the existing aggregate views.
- **Payload:** one aggregate query per envelope parameter in place of the thinning query, plus today's thinning of the short edges. About 288–400 buckets for a scalar. Up to 40,000 rows for a 100-element array in Lines mode, which is why that mode is off by default (see design).
- **Tests:** `History` envelope tests run outside the sandbox, as the aggregate tests do, since aggregates can't be refreshed in a transaction. LiveView tests cover the flag plumbing and the overview reload.
- **Bench:** `bench/history_plots.exs` gets envelope cases next to the thinning cases.
