# Proposal

## Why

#184 and #185 break lines and end heatmap rows where nothing was recorded. A gap then looks the same as a reading that just stopped, so someone reading the plot can't tell "not recorded" from "nothing changed", and can't see why recording stopped. Grafana's answer to this is an annotation region: a faint shaded band across the plot over the outage, with a description on hover. This change marks the gaps the same way.

## What Changes

- **A shaded region over each marked gap.** It is a faint, neutral band across the full height of the plot, with a thin dashed line at its start and end, drawn behind the data. It works in light and dark themes.
- **Only gaps the plot actually shows are marked.** That means a gap where a drawn line is broken or a heatmap row is ended, at the current zoom. A short gap at a coarse zoom, which the line bridges, gets no band, so the band never contradicts the line. A gap with no reading after it yet, including an open one (not recording now), is always marked.
- **An ongoing gap runs to the right edge** of the plot, as far as the time axis reaches. It has no end line and grows with the live plot.
- **The description on hover.** With the pointer inside a region, a readout shows "Not recorded", the reason, and the start, end and duration (or "ongoing"), instead of the readings. Outside regions, the tooltip is exactly as today. The reasons are:
  - node disconnected;
  - node deactivated;
  - recording stopped;
  - recording interrupted (a host suspend, or the server stopping without closing the span).
- **Gaps carry their reason.** The server sends each gap as `[g0, g1, reason]`, with the reason taken from the recording span that ended before it. A live plot's "recording stopped" event carries the reason too.
- **Plots covered:** the plots that break today:
  - number lines, including module plots with setpoints and envelope bands;
  - numeric array plots, as a heatmap or in Lines mode.

### Out of scope

- **Plots without breaks:** enum and struct plots, setpoint arrays, `ArrayLatest`, and the dashboard sparklines.
- **Breaks from the fallback** for sessions recorded before spans existed. They have no recorded reason and stay unmarked.
- **Export:** CSV and NeXus.
- **A list or table of outages**, or a switch to hide the regions.
- **Extending a time axis to show an open gap:** a history plot and the live "All" range end at the data.
- **The recording itself:** any change to spans, the tracker's close logic, or the database. No migration.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `plot-recording-gaps`: new requirements for marking gaps with a region, a hover description and the reasons shown. The heatmap readout requirement from `break-array-plots-at-recording-gaps` changes: inside a marked gap it describes the gap. The capability comes from `break-plots-at-recording-gaps` and is extended by `break-array-plots-at-recording-gaps`. Archive both first.

## Impact

- **Server:**
  - `PlotDB.Gaps` adds each gap's reason (the span query also selects `end_reason`).
  - `RecordingTracker` → `PlotCache` → `HistoryDB` / `DashboardLive`: the `{:recording, ...}` message carries the reason.
  - No new queries; about 15 bytes more per gap in the payload.
- **Chart hook:**
  - `assets/js/charts/gaps.mjs`: reasons in `mergeGaps`, the set of marked gaps, and the readout text, as pure functions with node tests.
  - `echarts_chart.js` and `live.js`: the region helper series on both patch paths.
  - `arrays.js`: the shared pointer readout, extended to every covered plot.
- **Database:** no migration.
