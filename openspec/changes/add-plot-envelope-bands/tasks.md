# Tasks

## 1. Envelope read in `History`

- [x] 1.1 Add the `envelope: true` option to `History.window/4` (design decisions 2 and 3).
  - For `{:buckets, from, to, bucket_ms}` with `bucket_ms >= 60_000`, compute `a` and `b` from `time_bucket`'s default origin (2000-01-03 UTC); return today's window with `envelope: nil` when `a >= b`.
  - Call `Aggregates.numbers(param, a, to, bucket_ms)` first, and take `until = max(a, min(b, floor(materialized_until)))` from its reply.
  - Then thin the head `[from, a)` (exclusive end) and the tail `[until, to]` with `bucketed/5` at `bucket_ms`. When the head or tail is empty, fetch the first or last stored reading in `[a, until)` whole and add it.
  - Build mean points at bucket centres clamped into each bucket's `[first_at, last_at]`, with the band row at the same `t`: scalars one value, arrays one mean array with `nil` holes. Sort all points by time.
  - Return `envelope: %{bucket_ms, from_ms, until_ms, rows}`. Rows are `[t, min, mean, max]` for scalars and `[t, i, min, mean, max]` with `i = idx - 1` for arrays; length rows are never band rows.
  - Return today's window with `envelope: nil` for other plans, for `{:error, _}` from `Aggregates`, and when the middle has no element rows. Without the option, the window keeps today's shape (no `envelope` key).
  
  Verify with `mix compile --warnings-as-errors`.
- [x] 1.2 Factor the edge computation into pure functions on integer milliseconds: `a`/`b` from `from`, `to` and `bucket_ms`, `until` from `a`, `b` and a `materialized_until` (or nil), and the clamped point time from a bucket and its `first_at`/`last_at`, and unit-test it in the existing `History` tests (`test/secop_service/plot_db/history_test.exs`). Cover:
  - aligned and unaligned edges;
  - a watermark before `a`, inside the window, and after `to`;
  - a nil watermark (never refreshed);
  - a 2-day width, and an instant before 2000;
  - `a >= b`;
  - a bucket whose only reading lies after its centre.
  
  Verify with `mix test test/secop_service/plot_db/history_test.exs`.
- [x] 1.3 Add `test/secant_service/plot_db/history_envelope_test.exs`, unboxed with `AggregateHelpers` like `aggregates_test.exs`, with explicit `max_raw`/`max_buckets` so the plan picks a 1-minute or wider width. Cover:
  - a double: the rows' min/mean/max, the mean points and their centres, and that `timestamps` start at the window's first reading and end at its last, where the last reading has a sub-millisecond fraction;
  - a double whose first reading falls exactly on a bucket boundary and has no earlier reading, and one whose first reading lies after the first bucket's centre: `timestamps` start at that reading in both cases;
  - a 2-day width with an unaligned start: `a` equals SQL's `time_bucket(w, from) + w` and `b` equals `time_bucket(w, to)`;
  - an array whose last reading in the window is shorter than an earlier one in its bucket, with an empty tail: the edge point is that last reading, whole;
  - unaligned window edges: head and tail hold the readings of the partial buckets, and a spike just outside the window is in no row;
  - readings inserted after the refresh, at times past the watermark the views report at test start, come back in the tail;
  - a window beyond the shared views' watermark, seeded relative to the watermark the views report at test start: it returns `envelope: nil`, and its other fields equal `window/4` without the option;
  - sub-minute and raw plans return `envelope: nil`;
  - a 3-element array: rows are 0-based with no length rows, and `values` holds one 3-element mean array per bucket centre;
  - a ragged array where element 3 is missing in one bucket: that bucket's mean array has `nil` at index 2.
  
  Verify with `mix test test/secant_service/plot_db/history_envelope_test.exs`.
- [x] 1.4 Document the envelope path in the `History` moduledoc and remove "Nothing reads these yet" from the `Aggregates` moduledoc. Verify by reading both moduledocs with `mix usage_rules.docs SecantService.PlotDB.History` and `mix usage_rules.docs SecantService.PlotDB.Aggregates`.

## 2. Action, eligibility and first load

- [x] 2.1 Add the `envelope` boolean argument (default `false`) to `:history_window` on `Parameter`, and pass it in `Actions.HistoryWindow`. Verify:
  - `mix ash.codegen --check` reports no changes;
  - a test in `test/secop_service/plot_db/history_test.exs` calls `SecNodes.history_window!(id, from, to, %{envelope: true})` and gets the `envelope` key.
- [x] 2.2 Add `PlotDB.envelope_params/1` (design decision 1). Verify in `test/secant_service/plot_db_test.exs`:
  - a double parameter (kind `"line"`), a 10-element array parameter (kind `"array"`), and a Readable's and a Drivable's numeric `value` (kind `"line"`) are listed;
  - a Drivable's `target` (in the module and opened on its own), an enum, a struct, a Calibratable and an Acquisition module are not.
- [x] 2.3 Thread the envelope through the first load:
  - `Builders.fetch_param_window/3` takes `envelope:` with default `false`; `parameter_plot`, `Readable.plot` and `Drivable.plot` pass `true` only for `envelope_params` members of kind `"line"` in `:historical` mode;
  - add `PlotDB.envelope_updates/3`;
  - set `_envelope` (historical, non-`ArrayLatest` plots only) and `_envelopes` on the option, and `envelope_bucket_ms` on `_windowFetch` when the first load has rows;
  - size array plots by rows as well as readings;
  - add `PlotDB.drop_nil_points/1`, which `HistoryDB` applies to array updates built from envelope windows (window and overview replies; the first load never reads an array as an envelope, so no other path sees mean arrays with holes).
  
  Verify in `test/secant_service/plot_db_test.exs` with hand-built envelope maps:
  - a double's option carries one envelope payload for series 0;
  - a Drivable's payload targets the `value` series and none targets `target`;
  - an array's payload carries 0-based element rows;
  - `drop_nil_points/1` removes the `nil` points of an array update, while the plain update path still produces a `nil` point for a NaN element, as today;
  - a live plot carries no `_envelope`;
  - the first loads of a Calibratable module, an Acquisition module and a standalone `target` parameter carry no `_envelope`; they never request an envelope, so their data is today's.

## 3. Window fetches and overview reload in `HistoryDB`

- [x] 3.1 Read `envelope` (only `true` counts) and `gen` from `fetch-chart-window`, pass `envelope` to `history_window!` for `envelope_params` only, and add `gen`, `envelopes`, `arrayLen`, `envelope_bucket_ms` and the applied `envelope` flag to the reply. Verify in `test/secant_service_web/live/node_browser_live_test.exs`. Historical plots render there, at `/browse/node/:uuid` via `module_detail` with `mode={:historical}`. Set up a node with a Drivable module and readings, mount the page, `render_async`, then send events with `render_hook(element(view, "#<plot id>"), ...)`. Check:
  - `envelope: true, gen: 3` gives a `window-chart-data-*` event that echoes `gen: 3` and `envelope: true` and has an `envelopes` key;
  - `envelope: "yes"` gives `envelope: false`.
  
  Aggregates can't be refreshed in the sandbox, so the payload contents are covered by 1.3 and 2.3.
- [x] 3.2 Add the `fetch-chart-overview` event (design decision 5):
  - run it on its own async key `:fetch_chart_overview`;
  - rebuild the first load's windows with the requested `envelope`;
  - reply with `overview-chart-data-<id>` carrying full series data, envelopes, resolution, `arrayLen`, the applied `envelope` and the request's `gen`;
  - push `overview-chart-error-<id>` with `gen` when the task exits, and rebuild as the latest-reading plot when the reload finds more than 100 elements.
  
  Verify in `node_browser_live_test.exs` (same setup as 3.1) that the reply arrives with the same `gen`, and that a `fetch-chart-window` sent while it runs doesn't cancel it (both events arrive).

## 4. Drawing envelopes in the chart hook (`assets/js/app.js`)

- [x] 4.1 Keep envelope payloads next to `_overview` and `_detail` (`_overviewEnvelopes`, `detail.envelopes`).
  - Merge band rows like line points: overview rows outside `[d.from, d.to]`, detail rows inside.
  - Insert aligned `null` rows into both helpers at every segment change.
  
  Verify in headless Chrome against the user-managed dev server (run-app skill) on a 72 h double recording:
  - fixture precondition: a recording of at least 1 reading/s and at least 72 h, so that a 4 h request is bucketed rather than raw;
  - a centred 2 h view still shows the envelope (1-minute buckets), and the reply carries `envelope_bucket_ms: 60000`;
  - a centred 90-minute view gets 30-second buckets and shows today's line in the zoomed window, with no band bridging it;
  - zooming back out restores the band.
- [x] 4.2 Build the helper series in `_composeOption` (design decision 6): lower and range per line or array element, unique `id` and `stack` key, `stackStrategy: "all"`, no sampling, `tooltip: {show: false}`, `silent`, `z` below lines, the parent's name and computed colour. They exist whenever the flag is on, empty where there are no rows. A line's sampling is off while its drawn data holds mean points and `lttb` otherwise; `_drawWindowData` sends `{data, sampling}` for lines. Extend `_seriesMap` with band entries, so `_drawWindowData` updates them. Verify in headless Chrome, in light and dark theme:
  - a double with values crossing zero;
  - a Drivable (band on `value` only);
  - a 10-element array in Lines mode, where each element's band is in its colour and bands don't stack on each other;
  - hiding `value` in the legend hides its band and keeps it hidden after a zoom;
  - a plot whose overview has no rows but whose zoomed window has them shows the band in the zoomed window, and none after zooming back out, with the line's sampling switching from `lttb` to off and back. This state doesn't occur in steady state, so stage it by calling the hook's reply handlers from the headless page with a synthetic overview payload without `envelopes` and a synthetic window payload with them.
- [x] 4.3 Add the axis-tooltip formatter for line plots with envelopes and extend `_linesTooltip` with `mean (min … max)`, read from the band row. Verify by hovering in headless Chrome that each line is listed once with its min and max. Also hover, via a synthetic payload, a bucket whose clamped mean point shares its `t` with an edge reading: the line is still listed once.
- [x] 4.4 Show "min/mean/max · <width> intervals" in `_renderResolution` when the shown window has `envelope_bucket_ms` (also on the first load), and today's labels otherwise. Verify in headless Chrome zoomed out and zoomed into a fallback window, and for "aggregates don't cover the window" by pushing a synthetic window payload without `envelopes` into the hook.

## 5. Envelope toggle, defaults and reloads

- [x] 5.1 Add the `envelope-toggle-<id>` slot (`phx-update="ignore"`, `empty:hidden`) right after the array-mode group in `HistoryDB.render/1`. Render the button from the hook when `_envelope` is set, and for arrays only in Lines mode. Verify:
  - `node_browser_live_test.exs` finds `#envelope-toggle-<id>` on a historical plot;
  - headless Chrome shows the button for a double and hides it for an enum, a struct, and an array in Heatmap mode.
- [x] 5.2 Read and write `secant:envelope` (default on) and `secant:envelope-array` (default off) in `try/catch`, compute the effective flag, and send it on every `fetch-chart-window`. Verify in headless Chrome with a fresh profile that a double shows the envelope and an array in Lines mode does not.
- [x] 5.3 Reload the overview on a flag change (design decision 5):
  - triggers: a toggle click, a Heatmap/Lines switch, or a first load whose `_envelope.on` differs from the effective flag;
  - bump `_envGen`, send `fetch-chart-overview`, send `gen` on window fetches too, drop any reply whose `gen` is not current, and hold `_fetchWindow()` while a reload is pending;
  - on the reply: replace `_overview`, rebuild `_seriesData`, update `_lastOption`, clear `_detail`, recompose with `notMerge` while keeping zoom and legend selection, then `_fetchWindow()`;
  - when the flag returns to the loaded overview's mode before the reply, clear `_detail` and `_fetchWindow()` at once;
  - in `_reinitForTheme`, clear `_detail` and reset `_seriesData` to the overview before composing;
  - on `overview-chart-error` for the current `gen`, drop the pending state, set the toggle back to the loaded mode, and resume zoom fetches;
  - grow `_arrayLen` from `arrayLen` on overview and window replies, and recompose in Lines mode when it grows.
  
  Verify in headless Chrome:
  - toggling off while zoomed redraws both the overview and the zoomed window as today's line at the same zoom;
  - toggling on and panning at once ends in an envelope for the panned window;
  - toggling on → off → on quickly ends in the envelope;
  - a theme switch after toggling keeps the chosen mode, for a double and for an array in Lines mode, zoomed and unzoomed;
  - an array toggled on in Lines mode stays on after a reload;
  - a synthetic `overview-chart-error` for the current `gen` puts the toggle back and zooming fetches windows again;
  - a synthetic window reply with a larger `arrayLen` adds the new element's line.

## 6. Integration checks

- [x] 6.1 Add envelope cases to `bench/history_plots.exs`: a double and a 50-element array over 72 h, and a double over a 4 h window, where the head and tail queries weigh most. Refresh the seeded range with the policies' batching before measuring (the bench refreshes aggregates only in its aggregate mode today), assert that each envelope case returns rows, and measure each with the envelope on against today's window. Record the timings in design.md's query-count table in place of the estimates. Run it only against the bench database, as the bench already does.
- [x] 6.2 In headless Chrome, check that a finished recording's time axis reaches its first and last reading with the envelope on, and that both ends can be zoomed into.
- [x] 6.3 Run `mix precommit` and fix anything it reports.
