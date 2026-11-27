# Design

## Context

- **How historical plots load today.**
  - `Builders.fetch_param_window(param, :historical)` calls the `:history_window` action, which runs `History.window/4` from `plot_start_ms` to the last reading and then `hold_from/4`.
  - `History.plan/4` returns `:empty`, `{:raw, from, to}` or `{:buckets, from, to, bucket_ms}` (`from`/`to` as `NaiveDateTime`).
  - The plot option carries `_windowFetch`. After a zoom or pan, the `EChartsChart` hook sends `fetch-chart-window` for the visible window padded by half its span on each side.
  - `HistoryDB` runs one `:fetch_chart_window` async task, cancelling the previous one, and replies with `window-chart-data-<id>`.
  - The hook drops any reply whose `req` is not the latest. It keeps the first load as `_overview` and the reply as `_detail`, and draws detail points inside `[d.from, d.to]` and overview points outside, with a data-only `setOption`.
- **Widths.** Every width in `@bucket_widths` from 1 minute up is a whole number of minutes, and every width from 1 hour up is a whole number of hours. So `Aggregates.numbers/4` reads any width `History` picks at 1 minute or more, from the 1-hour tier from 1 hour up, and returns `{:error, :unsupported_width}` below 1 minute.
- **When a 1 Hz scalar gets minute buckets.** `max_buckets` is 400 for scalars, and `bucket_width/2` picks the narrowest width that covers the requested span. So a 1 Hz scalar gets 1-minute buckets once the requested span exceeds 400 × 30 s ≈ 3.3 h (it gets wider buckets from about 6.7 h). The hook requests twice the visible span, so the envelope starts at about 1 h 40 min visible.
- **`Aggregates.numbers/4` returns** whole buckets inside `[time_bucket(w, from), time_bucket(w, to))` that end by `materialized_until`, together with `materialized_until` (for the 1-hour tier, the smaller of both tiers' watermarks). The width is passed as an interval of seconds, so `time_bucket` uses its default origin, 2000-01-03 00:00 UTC. `materialized_until` is a high-water mark, not a coverage guarantee (see `add-reading-aggregates`, decision 9).
- **Array plots:**
  - Their buffer is the heatmap's `[[t, i, v], ...]`. Lines mode splits it per element in `_composeOption`, and `_seriesMap` maps drawn series to buffers.
  - Heatmap vs Lines is the per-browser `localStorage` key `secant:array-mode`.
  - Arrays longer than 100 elements are drawn as their latest reading (`ArrayLatest`) and never as lines.
- **Scalar plots** use ECharts' default axis tooltip and take line colours from `CHART_PALETTE` by series index. Historical plots never extend from live readings (the flush loop skips `_windowFetch` charts).
- **`plot_available?/3`** is `length(vals) > 1` for historical plots.

## Goals / Non-Goals

**Goals:**
- The envelope uses the existing overview + detail flow. There is no second zoom mechanism.
- Whether a window gets an envelope is decided on the server from the same `plan/4` as today's thinning, so the fallback is exactly today's drawing.
- With the envelope on, the thinning query is skipped over the aggregated part of the window.

**Non-Goals:**
- Struct members, setpoints (`target`, `_target_calibrated`), enums and heatmaps. They keep today's drawing. Struct members can follow in a separate change.
- Bucket widths chosen for the envelope independently of `plan/4`.
- Server-side memory of the toggle.
- Detecting holes in the aggregates before `materialized_until` (see Risks).

## Decisions

### 1. Which series get an envelope: one server function

`PlotDB.envelope_params(secop_obj)` returns the parameters whose plotted line may carry an envelope:
- a `double`/`int`/`scaled` parameter plotted on its own;
- a numeric array parameter plotted on its own (as heatmap or lines);
- the `value` parameter of a Readable, Acquisition or Drivable module whose `value` is such a number or numeric array.

It returns `[{param, kind}]` with `kind` `"line"` or `"array"`. Only `:historical` plots use it; live plots and `ArrayLatest` plots never get an envelope. A Calibratable module lists its `value` and `_value_uncalibrated` when they are numbers (kind `"line"` only; its plot draws scalars). An Acquisition module (also AcquisitionChannel and AcquisitionController, which share its plot) lists its `value` as a Readable does (Acquisition delegates to `Readable.plot/2`). A parameter named `target` or `_target_calibrated` is never listed, also when it is opened on its own (the parameter browser can plot it alone): a setpoint is drawn as today, without a Band toggle. An array is listed only when its `maxlen` is at most 100, the heatmap's limit: a longer array is plotted as its latest reading once such a reading turns up, and an envelope read would load every element's aggregate rows before that check could run. The first load, the overview reload and every window fetch use this function: `Builders.fetch_param_window/3` takes `envelope:` with default `false`, and only `parameter_plot`, `Readable.plot`, `Drivable.plot` and `Calibratable.plot` pass `true`, for members of this list of kind `"line"`, in `:historical` mode. Arrays are never fetched with an envelope on the first load (their default is off). Every other parameter, including a Drivable's `target`, is always fetched with `envelope: false`, so its reply is exactly today's. The option gets `_envelope: %{kind: "line" | "array", on: boolean, series: [index]}` only when this list is non-empty; `series` lists the plot's series that may carry a band (two for a Calibratable). That flag decides whether the hook shows the toggle at all.

- **Alternative:** trying `Aggregates.numbers/4` and treating success as capability. It succeeds for a `target` and for structs with only array members, so it would put bands on lines that must not get them.

### 2. The envelope is an option of `History.window/4` and the `:history_window` action

`History.window(param, from, to, envelope: true)` runs `plan/4` as today. It builds an envelope only for `{:buckets, from, to, bucket_ms}` with `bucket_ms >= 60_000`; otherwise it returns today's window with `envelope: nil`. Without the option the window has today's shape, with no `envelope` key. The action gets an `envelope` boolean argument with default `false`, passed in the arguments map (`%{envelope: true}`), so current callers don't change.

### 3. Window split: head, aggregated middle, tail

With `w = bucket_ms`:

- `a` = the first bucket boundary at or after `from`, and `b` = the last at or before `to`. Both are computed in Elixir from `time_bucket`'s default origin (2000-01-03 00:00 UTC), in integer milliseconds with floor division (`Integer.floor_div/2`, so instants before 2000 work): `b = origin + floor_div(to - origin, w) * w`, and `a` the same with ceiling. If `a >= b` (possible with a small `max_buckets`), the window is returned as today with `envelope: nil`. A pure function holds this, and task 1.3 checks it against SQL's `time_bucket` for a 2-day width.
- The **middle** is one ordinary `Aggregates.numbers(param, a, to, w)` call, made first. Head and tail are read only after it returns; on `{:error, _}` the window is today's. Since `a` is aligned, the call reads exactly the whole buckets in `[a, b)` that end by the watermark, so no bucket reaches outside `[from, to]`. The public API stays as it is.
- `until` = `max(a, min(b, floor(materialized_until, w)))`, floored from the same origin, with `materialized_until` from the same reply converted to milliseconds. When `materialized_until` is nil, `until = a`.
- Only `a`, `b` and `until` are computed in milliseconds. The head and tail queries take the plan's own `from` and `to` (microsecond `NaiveDateTime`s) unchanged as their outer bounds, so the newest reading isn't dropped by truncation. The tail read starts after this reply, so nothing is circular and there is no extra watermark query.
- The **head** `[from, a)` (exclusive upper bound; today's reading query is inclusive at both ends, so the head query gets its own) and the **tail** `[until, to]` (inclusive, as today) are each less than a bucket in steady state, except during backfill. Each is always thinned with `bucketed/5` at `bucket_ms`, like today's line at this width, with no count query. At 1 Hz and 15-minute buckets that is a few points per edge instead of up to 900 raw readings.
- **Extent:** if the head is empty, the first stored reading in `[a, until)` is fetched whole (one indexed query, `ORDER BY timestamp LIMIT 1`) and added as a real point. If the tail is empty, the last one is fetched the same way. So the line always starts and ends at a real reading, also for arrays, whose aggregate `first`/`last` are picked per element and could mix readings.
- **Rows:** one per bucket, at the bucket centre `bucket + w/2`, clamped into that bucket's own `[first_at, last_at]` (of the scalar row, or of an array's length row). No point therefore lies outside the real readings: a bucket whose only reading is at 00:10 puts its point at 00:10, not at 00:07:30. The band row and the mean point of a bucket share that same `t`.
  - Scalar: mean point `{mean, t}` and band row `[t, min, mean, max]`. The band row repeats the mean, so the tooltip reads min, mean and max from one row.
  - Array: one mean array per bucket, `{[mean_0, mean_1, ...], t}`, with `nil` for an element that has no row in that bucket. This is the shape every array plot path already takes (one array per timestamp). Band rows stay flat: `[t, i, min, mean, max]`, with `i = idx - 1` (0-based, matching the heatmap index). The length row (`idx` 0) is never sent as a band row; only its `first_at`/`last_at` are used, to clamp the bucket's point.
- All points (held, head, edge, means, tail) are sorted by time before they are returned.
- **No envelope without rows:** if the middle has no element rows (only length rows, or none), the window is returned as today with `envelope: nil`. An empty middle with `until > a` means no readings were taken there, and today's thinning would also return nothing.
- **Gaps:** like today's line, the mean line and the band connect across empty buckets. There is no extra gap rule.

### 4. The server merges mean points into the line, and bands travel separately

- For an envelope line, the window's `values`/`timestamps` become head readings + mean points + tail readings, in time order. `hold_from/4` still prepends the held reading at `from` as today.
- The window also carries `envelope: %{bucket_ms, from_ms: a, until_ms: until, rows}`.
- `PlotDB.envelope_updates(plot, param, envelope)` matches on the plot type and turns this into `%{seriesIndex, bucket_ms, from, until, rows}` for the hook. A bare parameter plot has no `_param_dtype_modules`, so this is one function rather than a `DTypePlot` callback.
- The first load includes the same payload in the option (`_envelopes`). The hook's line handling stays as it is, because the line's data already holds the means.
- **Array width and availability:**
  - An array plot's element count is the larger of the longest reading and the highest row index + 1.
  - Mean arrays with holes only reach the browser through `HistoryDB`'s window and overview replies, since the first load never reads an array as an envelope. `HistoryDB` applies `PlotDB.drop_nil_points/1` to array updates built from envelope windows, so a hole adds no point. Every other path, including live `extend-chart` updates, keeps today's behaviour: a NaN element (decoded as `nil`) still makes a gap.
  - **Width in replies:** overview and window replies carry `arrayLen`, the larger of the longest reading and the highest row index + 1. Element rows can reveal a wider array than the thinned readings did, because wide arrays are thinned by whole-array extremes. The hook grows `_arrayLen` as `prepend-chart-data` does today, and recomposes in Lines mode when it grows. If an overview reload finds more than 100 elements, `HistoryDB` rebuilds the plot as the latest-reading plot, as `fetch-chart-range` does today (`{:rebuild, param}`).
  - Mean points are in `values`, so `plot_available?/3` needs no change; a fully aggregated window with no head or tail readings still has enough values.
- **Return contract:** `Builders.fetch_param_window/3` still returns `{values, timestamps, resolution}`; the window's `envelope` travels in the resolution map, which `History.coarsest/1` ignores and `put_resolution/2` and `PlotDB.put_envelopes/4` read.
- **First-load label:** `put_resolution/2` also puts `envelope_bucket_ms` on `_windowFetch` when the first load has envelope rows (decision 7).

### 5. Requests: a separate overview request with its own generation

- **Effective flag** in the hook: `preference && (kind == "line" || Lines mode)`. Preferences live in `localStorage` under `secant:envelope` (default on) and `secant:envelope-array` (default off), read and written in `try/catch`.
- **First load:** the server uses the default for the plot kind: on for line plots, off for arrays. It sets `_envelope.on` to what it used.
- **Overview reload:** when the effective flag differs from what the overview was built with (after the first load, a toggle click, or a Heatmap/Lines switch), the hook sends a new event `fetch-chart-overview` with `envelope` and `gen`.
  - `HistoryDB` runs it on its own async key, `:fetch_chart_overview`, which cancels only an older overview reload.
  - It reuses the window pipeline rather than `PlotSpec.plot/2` (which takes no options): for each of `PlotDB.history_params/1`, `Builders.fetch_param_window(param, :historical, envelope: …)` with the flag only for `envelope_params`, then `get_trace_updates_batch/3` and `envelope_updates/3`.
  - It replies with `overview-chart-data-<id>`, carrying full series data, envelopes, resolution, `arrayLen`, `gen`, and `envelope`: the flag the server actually applied after the "only `true` counts" rule.
  - If the task exits, `HistoryDB` pushes `overview-chart-error-<id>` with the request's `gen`. For the current `gen`, the hook drops the pending state, sets the toggle back to the loaded overview's mode (`_overviewEnvelope`), and resumes zoom fetches in that mode.
- **Generation:** `_envGen` starts at 0 on each first load and is bumped on every flag change. Overview and window requests both carry `gen`, and their replies echo it. The hook drops any reply whose `gen` is not the current one, so an on → off → on sequence can't apply an old reply. Window replies must also match the latest `req`, as today.
- **Loaded mode:** the hook remembers which flag the current `_overview` was built with (`_overviewEnvelope`). While a reload is pending, `_fetchWindow()` does nothing. When the flag changes back to `_overviewEnvelope` before the reload's reply (on → off → on), the pending reload is abandoned (its `gen` is now stale), `_detail` is cleared and `_fetchWindow()` runs at once, so the visible window is refetched in the restored mode.
- **On an overview reply,** the hook:
  1. replaces `_overview` and `_overviewEnvelopes`;
  2. rebuilds `_seriesData` from the new overview, since array composition reads it;
  3. writes the new series data into `_lastOption`, so a theme rebuild (`_reinitForTheme`) draws the current mode;
  4. sets `_resolution` and clears `_detail`;
  5. recomposes the chart (decision 6);
  6. calls `_fetchWindow()` if zoomed in.

  The detail request therefore starts only after the overview has arrived, and the two never cancel each other.
- **Window fetches** send `envelope` (the effective flag) and `gen`. The reply echoes `gen`, carries `envelopes` (the same list shape as the overview's) and `arrayLen`, and echoes `envelope` as the flag the server applied. `HistoryDB` passes it only for `envelope_params`, and treats anything but `true` as `false`.
- **Alternative:** one server job that returns overview and detail together. It needs a combined reply shape and a second code path for plain zooms.

### 6. Drawing the band

- **Series:**
  - While the effective flag is on, every eligible line (and every element of an array in Lines mode) always has its two helper series, empty where there are no rows. So a detail reply that brings the first rows (an overview without rows, a zoomed window with them) only fills data.
  - A line's `sampling` is off while its drawn data holds mean points, so no bucket mean is dropped, and `lttb` as today otherwise. `_drawWindowData` therefore sends `{data, sampling}` for line entries, not only `data`, so a detail reply that brings the first means, or removes the last ones, switches it. In a mixed view (overview means around a fallback detail window) sampling is off, and the fallback part shows the points the server picked, which are already thinned.
  - Each envelope line gets two helper series, appended after all other drawn series so the server's `seriesIndex` values stay put:
    - a lower series: `min`, with no line;
    - a range series: `max - min`, stacked on the lower one, with `areaStyle` in the line's colour at low opacity.
  - Both helpers have:
    - a stable `id` and a `stack` key unique to that line or array element;
    - `stackStrategy: "all"`, so negative values and zero crossings stack correctly;
    - `sampling` off, so ECharts' stack pairs points by index;
    - `tooltip: {show: false}`, `silent: true`, no symbols, `z: 1` (lines keep ECharts' default `z: 2`), and `animation: false`;
    - the parent line's `name`, so its legend entry hides the band too.
  - Their colour is computed in the hook: `CHART_PALETTE[i % n]` for line plots, `arrayLineColor(i, n)` for array elements.
- **Mapping:** `_seriesMap` gets entries `{src, elem, band: "lower" | "range"}`, so `_chartSeriesData()` returns the band data in drawn order. Scalar plots get a `_seriesMap` too while they have bands.
- **Merging overview and detail:**
  - Band rows go through the same filter as line points: overview rows with `t < d.from` or `t > d.to`, and detail rows inside.
  - A `null` row goes into both helpers wherever two consecutive rows come from different envelope segments (overview before the detail, the detail, overview after it), or where one side has no envelope. This stops a band from bridging a fallback window.
  - Lower and range are built from the same ordered rows, so their nulls line up.
- **Redraws:** when the flag changes (overview reply, Heatmap/Lines switch), the hook recomposes with `notMerge` and restores the zoom, as `_redrawArray` does. It also keeps the legend's `selected` state. A detail reply in the same mode stays a data-only update over the mapped series. `_reinitForTheme` clears `_detail` and resets `_seriesData` to the overview **before** composing (today it clears after), so a rebuilt array chart doesn't draw stale buffers.
- **Tooltip:**
  - Line plots with an envelope get an axis-tooltip formatter. It lists each visible parent line once. Where a band row has the point's `t`, it shows `mean (min … max)` from that row. Otherwise it shows the point's value. A clamped mean point can share its `t` with a real edge reading, and ECharts may pass both; the formatter groups by series and uses the band row, so the line still appears once.
  - `_linesTooltip` does the same per element.
- **Alternatives:**
  - A `custom` polygon series. It needs its own hit-testing and gets no progressive rendering.
  - Separate `(min)`, `(mean)`, `(max)` legend entries, as in the reference picture. Three entries per line crowd Drivable plots.

### 7. Resolution label

- The reply's resolution gains `envelope_bucket_ms`, taken from the envelope's own width. It is set only when the shown window has envelope rows.
- With it, `_renderResolution` shows "min/mean/max · 15 min intervals", with a title explaining the band and that zooming in shows the readings.
- Without it, the label is today's "thinned · …" or "every reading", computed as now with `History.coarsest/1`, which ignores envelopes.

### 8. Toggle placement

- The toggle is a button in a new `phx-update="ignore"` slot (`envelope-toggle-<id>`), placed right after the `array-mode-<id>` group and before the spacer and `resolution-<id>`, filled by the hook.
- It uses `aria-pressed` and `_styleRangeButton`.
- It is shown only when the option has `_envelope`, and for arrays only in Lines mode.

### Query count and payload on a long recording

72 h at 1 reading/s, 15-minute buckets (288 in the window), envelope on, aggregates current. Measured with `bench/history_plots.exs` (task 6.1): `History.window/4` with and without `envelope: true`, median of 5 runs, 1-minute views compressed:

| Window | Queries (envelope / today) | Envelope | Today's thinning | Sent with the envelope |
|---|---|---|---|---|
| `double`, 72 h, 15-min buckets | 4 / 2 | 13.7 ms | 40.7 ms | 287 mean points + 287 band rows (≈ 15 KB JSON) + a few head/tail points |
| 50-element array, 72 h, 15-min buckets | 4 / 2 | 302 ms | 4,384 ms | 287 mean arrays of 50 + 14,350 band rows (≈ 0.7 MB) |
| `double`, 4 h, 1-min buckets | 4 / 2 | 7.1 ms | 8.1 ms | 239 mean points + 239 band rows |

The four queries are the capped count, the aggregate read, and the thinning of the head and the tail (an edge reading is fetched only when one of them is empty). A 100-element array in Lines mode (the widest drawn as lines) sends up to 400 × 100 = 40,000 band rows (≈ 3 MB) drawn as 300 series; that is why arrays default to off. A Drivable plot runs this for `value` and today's path for `target`. Zoomed windows run the same queries over the requested window. Below a 1-minute width, nothing changes. During backfill the tail is most of the window, so the cost and the drawing are today's.

## Risks / Trade-offs

- **[The envelope appears only from about 1 h 40 min visible for a 1 Hz scalar]** Narrower views get sub-minute buckets. → Accepted: this is the requested fallback. Fewer buckets for envelopes would start it sooner but coarser, and can be tuned later.
- **[Holes and staleness before the watermark]** A manual refresh over a limited range, late inserts or a purge can leave buckets before `materialized_until` missing or stale until the next refresh. In a missing bucket, the envelope shows nothing where readings exist. → Accepted and stated in the spec: the guarantee covers data after the materialized point only. Policy refreshes run oldest first, so in normal operation there are no holes.
- **[Many series for wide arrays]** 100 elements make 300 series. → Off by default for arrays. The helpers are silent, symbol-free and unanimated.
- **[A preference mismatch costs one extra overview load]** Only for users who changed a default. → Accepted.
- **[Mean points briefly shown as a heatmap]** Switching an array with the envelope on to Heatmap shows mean points as cells until the overview reload arrives. → Accepted. It is a short transition, and they are valid per-bucket values.
- **[Isolated bucket]** A bucket with empty buckets on both sides has a zero-width band. It shows as the mean point's marker. → Accepted.

## Migration Plan

- No database migration. The change reads the existing aggregate views and does not touch `readings` or its hypertable chunks.
- Deploy is code only. The new action argument defaults to `false`.
- Rollback: revert the code. The two `localStorage` keys are ignored by older builds.
