// Gaps: time in which a session was not recorded. The server sends them as
// intervals [g0, g1] or [g0, g1, reason] (ms; g1 null when no recording
// followed; reason: why recording stopped) with every
// load of a number-line or numeric array plot (`_gaps` on the option, `gaps`
// on window, overview and range replies), and live plots get
// `gap-chart-<id>` events when recording stops or resumes. The lines break
// there, and heatmap rows end there, once, on the data as drawn: after the
// overview, the zoomed detail, live backfill and live readings are merged,
// so no seam between them can erase or invent a break. Each gap the plot
// shows that way is marked with a shaded region, which the pointer readout
// describes. See SecantService.PlotDB.Gaps.
//
// The functions below are pure (tested with `node --test`); `Gaps` is the
// part of the EChartsChart hook (see ./echarts_chart.js) that feeds them.

const MIN_GAP_MS = 2000;
// fallback for sessions without spans: a spacing this many poll intervals
// wide, and at least this long, is a gap
const FALLBACK_FACTOR = 5;
const FALLBACK_MIN_MS = 60_000;
// the size of a line's markers (Scalar's @markersize)
const GAP_MARKER_SIZE = 5;

const end = (g) => (g[1] == null ? Infinity : g[1]);

// a gap, with its reason when there is one
const gapOf = (g0, g1, reason) => (reason == null ? [g0, g1] : [g0, g1, reason]);

// The gaps to draw: every gap ever received, with the live transitions on
// top. An open gap ends at a finite gap with the same start (a later load
// knows how it ended) or at a live close at or after its start; gaps that
// overlap are joined, never clipped. A gap keeps its reason; joined gaps
// keep the earliest one known.
export function mergeGaps(sets, liveEvents = []) {
  let gaps = [];
  sets.forEach((set) => (set || []).forEach(([g0, g1, r]) => gaps.push(gapOf(g0, g1 == null ? null : g1, r))));

  [...liveEvents]
    .sort((a, b) => a.ms - b.ms || (a.at || 0) - (b.at || 0))
    .forEach((ev) => {
      if (ev.kind === "open") {
        gaps.push(gapOf(ev.ms, null, ev.reason));
      } else {
        // the latest open gap that started at or before it
        let best = -1;
        gaps.forEach((g, k) => {
          if (g[1] == null && g[0] <= ev.ms && (best < 0 || g[0] > gaps[best][0])) best = k;
        });
        if (best >= 0) gaps[best] = gapOf(gaps[best][0], Math.max(ev.ms, gaps[best][0]), gaps[best][2]);
      }
    });

  // an open gap gives way to a finite one with the same start, which takes
  // its reason when it has none
  const finite = new Map();
  gaps.forEach((g) => g[1] != null && !finite.has(g[0]) && finite.set(g[0], g));
  gaps.forEach((g) => {
    const f = g[1] == null && finite.get(g[0]);
    if (f && f[2] == null && g[2] != null) f[2] = g[2];
  });
  gaps = gaps.filter((g) => g[1] != null || !finite.has(g[0]));

  gaps.sort((a, b) => a[0] - b[0]);
  const out = [];
  gaps.forEach((g) => {
    const last = out[out.length - 1];
    if (last && g[0] <= end(last)) {
      if (end(g) > end(last)) last[1] = g[1];
      if (last[2] == null && g[2] != null) last[2] = g[2];
    } else {
      out.push(gapOf(g[0], g[1], g[2]));
    }
  });
  return out;
}

// Gaps of a line of a session without spans, from the spacing of its points
export function spacingGaps(data, pollMs, widthAt = () => 0) {
  const gaps = [];
  for (let k = 1; k < data.length; k++) {
    const a = data[k - 1][0];
    const b = data[k][0];
    if (b <= a) continue;
    // further apart than 5 poll intervals (or buckets), and at least a minute
    if (b - a > FALLBACK_FACTOR * Math.max(pollMs, widthAt(a, b)) && b - a >= FALLBACK_MIN_MS) gaps.push([a, b]);
  }
  return gaps;
}

const overlap = (a, b, g) => Math.min(b, end(g)) - Math.max(a, g[0]);

// A line other than a setpoint, with a break where a gap lies between two
// consecutive points: per gap the pair whose time between them overlaps it
// most, if that overlap is at least the width the gap is judged at (2 s, or
// the bucket width of the part it lies in). The line holds the last value
// up to the gap start, then breaks. A pair breaks once, at its earliest gap.
// Returns {data, breaks}: the times of the breaks, for the band. `used`
// collects every gap that qualifies at a pair, also one whose pair already
// broke at an earlier gap: the line shows them all.
export function breakLine(data, gaps, { widthAt = () => 0, used } = {}) {
  if (gaps.length === 0 || data.length < 2) return { data, breaks: [] };
  const breakAt = new Map(); // pair index -> gap
  gaps.forEach((g) => {
    const min = Math.max(MIN_GAP_MS, widthAt(g[0], end(g)));
    let best = -1;
    let bestOverlap = 0;
    // pairs that can overlap the gap: from the last point at or before g0
    let k = firstPairFrom(data, g[0]);
    for (; k < data.length - 1; k++) {
      const a = data[k][0];
      const b = data[k + 1][0];
      if (a >= end(g)) break;
      if (b <= a) continue;
      const o = overlap(a, b, g);
      if (o > bestOverlap) {
        best = k;
        bestOverlap = o;
      }
    }
    if (best >= 0 && bestOverlap >= min) {
      if (used) used.add(g);
      if (!breakAt.has(best)) breakAt.set(best, g);
    }
  });
  if (breakAt.size === 0) return { data, breaks: [] };

  const out = [];
  const breaks = [];
  data.forEach((p, k) => {
    out.push(p);
    const g = breakAt.get(k);
    if (!g) return;
    const a = p[0];
    const x = Math.min(Math.max(g[0], a), data[k + 1][0]);
    if (x > a) out.push([x, p[1]]);
    out.push([x, null]);
    breaks.push(x);
  });
  return { data: out, breaks };
}

// index of the pair that starts at the last point at or before t (data in
// time order; a few out of order are harmless: the scan then starts earlier)
function firstPairFrom(data, t) {
  let lo = 0;
  let hi = data.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (data[mid][0] <= t) lo = mid;
    else hi = mid - 1;
  }
  return Math.max(0, lo - 1);
}

// A setpoint (step line) breaks at every gap: it ends at the gap start with
// the value in force, draws nothing inside the gap (a reading stamped
// inside takes effect at its end) and resumes at the gap end with the value
// in force there. A gap without an end ends the line. `used` collects the
// gaps it ended the line at (a value was in force).
export function breakHeld(data, gaps, { widthAt = () => 0, used } = {}) {
  const qualifying = gaps.filter((g) => end(g) - g[0] >= Math.max(MIN_GAP_MS, widthAt(g[0], end(g))));
  if (qualifying.length === 0 || data.length === 0) return data;
  const out = [];
  let value;
  let i = 0;
  for (const g of qualifying) {
    while (i < data.length && data[i][0] <= g[0]) {
      out.push(data[i]);
      value = data[i][1];
      i++;
    }
    if (value !== undefined) {
      out.push([g[0], value], [g[0], null]);
      if (used) used.add(g);
    }
    const stop = end(g);
    while (i < data.length && data[i][0] < stop) {
      value = data[i][1];
      i++;
    }
    if (g[1] == null) return out;
    if (value !== undefined && !(i < data.length && data[i][0] === g[1])) out.push([g[1], value]);
  }
  while (i < data.length) out.push(data[i++]);
  return out;
}

// Band rows ({t, ...} or null) with a break wherever the line broke between
// two consecutive rows
export function breakRows(rows, breaks) {
  if (breaks.length === 0) return rows;
  const out = [];
  let b = 0;
  const sorted = [...breaks].sort((x, y) => x - y);
  rows.forEach((r, k) => {
    const prev = k > 0 ? rows[k - 1] : null;
    if (r && prev) {
      while (b < sorted.length && sorted[b] < prev.t) b++;
      if (b < sorted.length && sorted[b] < r.t) out.push(null);
    }
    out.push(r);
  });
  return out;
}

// A heatmap's row ends ([times[k], ends[k]] is the hold of reading k), each
// ended at the start of the earliest gap its hold overlaps by at least the
// width the gap is judged at (2 s, or the bucket width), or of an open gap
// it reaches (recording stopped). A row never ends before its reading and
// is never longer than before. Rows and gaps are in time order. `used`
// collects each gap that ends a row or qualifies inside a row's hold.
export function clipRowEnds(times, ends, gaps, { widthAt = () => 0, used } = {}) {
  if (gaps.length === 0) return ends;
  const out = ends.slice();
  let first = 0;
  for (let k = 0; k < times.length; k++) {
    const t = times[k];
    const e = ends[k];
    while (first < gaps.length && end(gaps[first]) <= t) first++;
    for (let j = first; j < gaps.length && gaps[j][0] < e; j++) {
      const g = gaps[j];
      const ge = end(g);
      const reaches = g[1] == null || Math.min(e, ge) - Math.max(t, g[0]) >= Math.max(MIN_GAP_MS, widthAt(g[0], ge));
      if (!reaches) continue;
      if (out[k] === e) out[k] = Math.min(e, Math.max(t, g[0]));
      if (!used) break;
      used.add(g);
    }
  }
  return out;
}

// The marked gap under time t: regions in time order, not overlapping
export function gapAt(t, regions) {
  let lo = 0;
  let hi = regions.length - 1;
  if (hi < 0 || t < regions[0][0]) return null;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (regions[mid][0] <= t) lo = mid;
    else hi = mid - 1;
  }
  return t < end(regions[lo]) ? regions[lo] : null;
}

const REASONS = {
  disconnected: "Node disconnected",
  deactivated: "Node deactivated",
  stopped: "Recording stopped",
  interrupted: "Recording interrupted",
};

// The readout of a gap, one line each: what, why, when. `time` and
// `duration` format ms (passed in: their module needs a browser).
export function gapText(g, now, { time, duration }) {
  const lines = ["Not recorded"];
  if (REASONS[g[2]]) lines.push(REASONS[g[2]]);
  lines.push(
    g[1] == null
      ? `since ${time(g[0])} · ${duration(Math.max(0, now - g[0]))}, ongoing`
      : `${time(g[0])} → ${time(g[1])} · ${duration(g[1] - g[0])}`,
  );
  return lines.join("\n");
}

// The marks of the regions: a shaded area each (an open one to the right
// edge), and a dashed line at each start and end
export function regionMarks(regions) {
  return {
    areas: regions.map((g) => [{ xAxis: g[0] }, { xAxis: end(g) }]),
    lines: regions.flatMap((g) => (g[1] == null ? [{ xAxis: g[0] }] : [{ xAxis: g[0] }, { xAxis: g[1] }])),
  };
}

export const hasNull = (data) => data.some((p) => Array.isArray(p) && p[1] == null);

// Indexes of readings a break left on their own (nulls, or the ends of the
// data, on both sides): without a marker they would not show at all
export function isolatedPoints(data) {
  const out = new Set();
  if (!hasNull(data)) return out;
  const gone = (k) => k < 0 || k >= data.length || data[k][1] == null;
  data.forEach((p, k) => {
    if (p[1] != null && gone(k - 1) && gone(k + 1)) out.add(k);
  });
  return out;
}

export const Gaps = {
  // Server events of gaps: recording stopped or resumed while a live plot
  // is open.
  _listenGaps() {
    this._gapLive = [];
    this.handleEvent(`gap-chart-${this.el.id}`, (ev) => {
      this._gapLive.push(ev);
      this._gapsChanged();
    });
  },

  // a new chart (the option, also sent again): its gaps
  _resetGaps(gaps) {
    this._gapsOn = !!gaps;
    this._gapSets = gaps ? [gaps.gaps || []] : [];
    this._gapFallback = (gaps && gaps.fallback) || {};
    this._liveRanges = [];
    this._gapCache = null;
  },

  // gaps of a reply (window, overview, live range)
  _addGaps({ gaps, fallback }) {
    if (!this._gapsOn) return;
    if (Array.isArray(gaps)) this._gapSets.push(gaps);
    if (fallback) this._gapFallback = fallback;
    this._gapCache = null;
  },

  _gapsChanged() {
    this._gapCache = null;
    this._dataDirty = true;
    // a historical chart has no flush loop: redraw now
    if (this._chart && !this._rangeButtons) this._chart.setOption({ series: this._seriesPatch() });
  },

  _gapList() {
    if (!this._gapCache) this._gapCache = mergeGaps(this._gapSets || [], this._gapLive || []);
    return this._gapCache;
  },

  // The bucket width a gap is judged at: the finest part of the plot it
  // reaches into (raw parts: 0)
  _gapWidth(g0, g1) {
    if (this._rangeButtons) {
      if (g1 >= this._rawFrom) return 0;
      let w = null;
      (this._liveRanges || []).forEach((r) => {
        if (r.from <= g1 && r.to >= g0) w = w == null ? r.bucket_ms : Math.min(w, r.bucket_ms);
      });
      return w == null ? 0 : w;
    }
    const res = this._resolution;
    const wo = res && res.aggregated ? res.bucket_ms || 0 : 0;
    const d = this._detail;
    if (d && g0 <= d.to && g1 >= d.from) return Math.min(d.aggregated ? d.bucket_ms || 0 : 0, wo);
    return wo;
  },

  _isHeldSeries(idx) {
    return !!(this._targetIdx && this._targetIdx.has(String(idx)));
  },

  // an array plot (heatmap or its element lines; not a struct)
  _gapArray() {
    return !!(this._isArrayPlot && this._isArrayPlot());
  },

  // the data of buffer `idx` with its breaks, and the times it broke at. An
  // array plot's buffer is heatmap cells, not a line: it stays as it is
  // (its rows end in `_heatRowEnds`, its element lines in `_elementLine`).
  _broken(idx) {
    const d = this._seriesData[idx] || [];
    if (!this._gapsOn || this._gapArray()) return { data: d, breaks: [] };
    const widthAt = (a, b) => this._gapWidth(a, b);
    let gaps = this._gapList();
    const poll = this._gapFallback[idx];
    // inferred gaps stay apart: each spacing breaks its own pair
    if (poll && !this._rangeButtons)
      gaps = [...gaps, ...spacingGaps(d, poll, widthAt)].sort((a, b) => a[0] - b[0]);
    if (gaps.length === 0) return { data: d, breaks: [] };
    // the gaps behind the breaks are marked (inferred ones are not in
    // `_gapList()`, so they never are)
    const used = this._marked;
    if (this._isHeldSeries(idx)) return { data: breakHeld(d, gaps, { widthAt, used }), breaks: [] };
    return breakLine(d, gaps, { widthAt, used });
  },

  // What series `idx` draws: its breaks, then a setpoint's hold to the end
  _drawnData(idx) {
    const { data } = this._broken(idx);
    return this._isHeldSeries(idx) ? this._heldTarget(data) : data;
  },

  // the times a band's line broke at
  _lineBreaks(src) {
    return this._gapsOn ? this._broken(src).breaks : [];
  },

  // An array element line with its breaks (Lines mode)
  _elementLine(data) {
    if (!this._gapsOn || this._gapList().length === 0) return data;
    const widthAt = (a, b) => this._gapWidth(a, b);
    return breakLine(data, this._gapList(), { widthAt, used: this._marked }).data;
  },

  // The ends of a heatmap's rows, ended at gaps
  _heatRowEnds(times, ends, used) {
    if (!this._gapsOn || this._gapList().length === 0) return ends;
    return clipRowEnds(times, ends, this._gapList(), { widthAt: (a, b) => this._gapWidth(a, b), used });
  },

  // A heatmap's rows from its cells [t, index, value] in time order: the
  // reading times, and how long each holds (to the next reading; the last
  // to now when live, else for one typical interval)
  _heatRows(timeAt, n, live) {
    const starts = [];
    const times = [];
    for (let j = 0; j < n; j++) {
      const t = timeAt(j);
      if (j === 0 || t !== times[times.length - 1]) {
        starts.push(j);
        times.push(t);
      }
    }
    const g = times.length;
    const lastSpan = g > 1 ? times[g - 1] - times[g - 2] : 1000;
    const held = times.map((t, k) => (k + 1 < g ? times[k + 1] : live ? Math.max(Date.now(), t) : t + lastSpan));
    return { starts, times, held };
  },

  // --- Marking the gaps the plot shows --------------------------------------

  // Before the series data is computed: collect anew. The breaks add the
  // gaps they used (`_broken`, `_elementLine`).
  _markBegin() {
    this._marked = this._gapsOn ? new Set() : null;
    this._regions = null;
  },

  // After it: a heatmap's rows add theirs, then the regions are the gaps
  // marked, plus those at the ends of the readings (see `_edgeGap`).
  _markEnd() {
    if (!this._marked) return;
    if (this._gapArray() && this._arrayMode !== "lines") {
      const cells = this._seriesData[0] || [];
      const { times, held } = this._heatRows((j) => cells[j][0], cells.length, !!this._rangeButtons);
      this._heatRowEnds(times, held, this._marked);
    }
    const span = this._readingSpan();
    const marked = this._marked;
    this._regions = this._gapList().filter((g) => marked.has(g) || this._edgeGap(g, span));
  },

  // The first and last reading in the buffers (recorded readings, not the
  // points added to draw them), or null without any
  _readingSpan() {
    let first = Infinity;
    let last = -Infinity;
    Object.values(this._seriesData || {}).forEach((d) => {
      if (!d || d.length === 0) return;
      first = Math.min(first, this._pointTs(d[0]));
      last = Math.max(last, this._pointTs(d[d.length - 1]));
    });
    return first === Infinity ? null : { first, last };
  },

  // A gap at an end of the readings shows though no line breaks there: no
  // reading after it yet (an open gap always), or none before it (a live
  // range trimmed it, or the plot was opened during the gap)
  _edgeGap(g, span) {
    if (!span) return true;
    return end(g) > span.last || g[0] < span.first;
  },

  // The marked regions, in time order (computed with the series data)
  _gapRegions() {
    return this._regions || [];
  },

  // The data patch of drawn series `j` with gaps in play, or null for the
  // ordinary one: number lines (their fallback breaks come with an empty
  // gap list), and array element lines while there are gaps. Bands and a
  // heatmap's own series take the ordinary patch.
  _gapPatch(data, j) {
    if (!this._gapsOn) return null;
    const m = this._seriesMap && this._seriesMap[j];
    if (m && m.band) return null;
    if (this._gapArray() && (!m || m.elem == null || this._gapList().length === 0)) return null;
    const symbol = this._symbols ? this._symbols[j] : undefined;
    return { ...this._gapDataPatch(data, symbol), sampling: this._sampling(data, false) };
  },

  // A line's data patch: a reading a break left on its own gets a marker
  // (a circle where the line has none), the others none (they show on
  // hover, as without gaps).
  _gapDataPatch(data, symbol) {
    const alone = isolatedPoints(data);
    if (alone.size === 0 || this._lone(data)) {
      // a fixed symbol and size again, replacing the callback set before
      const patch = this._dataPatchOf(data, symbol);
      return { ...patch, symbol: patch.symbol || "emptyCircle", symbolSize: GAP_MARKER_SIZE };
    }
    const marker = symbol && symbol !== "none" ? symbol : "circle";
    // the symbol, not the size, picks the marked readings: ECharts creates no
    // element for "none", but one per point for a zero size
    return {
      data,
      showSymbol: true,
      symbol: (_value, params) => (alone.has(params.dataIndex) ? marker : "none"),
      symbolSize: GAP_MARKER_SIZE,
    };
  },

  // sampling of a drawn line: LTTB keeps one null per frame, so a line with
  // breaks (or a band) is not sampled
  _sampling(data, banded) {
    return banded || hasNull(data) ? "none" : "lttb";
  },
};
