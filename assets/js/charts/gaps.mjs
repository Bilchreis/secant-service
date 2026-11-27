// Gaps: time in which a session was not recorded. The server sends them as
// intervals [g0, g1] (ms; g1 null when no recording followed) with every
// load of a number-line plot (`_gaps` on the option, `gaps` on window,
// overview and range replies), and live plots get `gap-chart-<id>` events
// when recording stops or resumes. The lines break there, once, on the data
// as drawn: after the overview, the zoomed detail, live backfill and live
// readings are merged, so no seam between them can erase or invent a break.
// See SecantService.PlotDB.Gaps.
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

// The gaps to draw: every gap ever received, with the live transitions on
// top. An open gap ends at a finite gap with the same start (a later load
// knows how it ended) or at a live close at or after its start; gaps that
// overlap are joined, never clipped.
export function mergeGaps(sets, liveEvents = []) {
  let gaps = [];
  sets.forEach((set) => (set || []).forEach(([g0, g1]) => gaps.push([g0, g1 == null ? null : g1])));

  [...liveEvents]
    .sort((a, b) => a.ms - b.ms || (a.at || 0) - (b.at || 0))
    .forEach((ev) => {
      if (ev.kind === "open") {
        gaps.push([ev.ms, null]);
      } else {
        // the latest open gap that started at or before it
        let best = -1;
        gaps.forEach((g, k) => {
          if (g[1] == null && g[0] <= ev.ms && (best < 0 || g[0] > gaps[best][0])) best = k;
        });
        if (best >= 0) gaps[best] = [gaps[best][0], Math.max(ev.ms, gaps[best][0])];
      }
    });

  const finiteStarts = new Set(gaps.filter((g) => g[1] != null).map((g) => g[0]));
  gaps = gaps.filter((g) => g[1] != null || !finiteStarts.has(g[0]));

  gaps.sort((a, b) => a[0] - b[0]);
  const out = [];
  gaps.forEach((g) => {
    const last = out[out.length - 1];
    if (last && g[0] <= end(last)) {
      if (end(g) > end(last)) last[1] = g[1];
    } else {
      out.push([g[0], g[1]]);
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
// Returns {data, breaks}: the times of the breaks, for the band.
export function breakLine(data, gaps, { widthAt = () => 0 } = {}) {
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
    if (best >= 0 && bestOverlap >= min && !breakAt.has(best)) breakAt.set(best, g);
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
// in force there. A gap without an end ends the line.
export function breakHeld(data, gaps, { widthAt = () => 0 } = {}) {
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

  // the data of buffer `idx` with its breaks, and the times it broke at
  _broken(idx) {
    const d = this._seriesData[idx] || [];
    if (!this._gapsOn) return { data: d, breaks: [] };
    const widthAt = (a, b) => this._gapWidth(a, b);
    let gaps = this._gapList();
    const poll = this._gapFallback[idx];
    // inferred gaps stay apart: each spacing breaks its own pair
    if (poll && !this._rangeButtons)
      gaps = [...gaps, ...spacingGaps(d, poll, widthAt)].sort((a, b) => a[0] - b[0]);
    if (gaps.length === 0) return { data: d, breaks: [] };
    if (this._isHeldSeries(idx)) return { data: breakHeld(d, gaps, { widthAt }), breaks: [] };
    return breakLine(d, gaps, { widthAt });
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

  // A number line's data patch: a reading a break left on its own gets a
  // marker, the others none (they show on hover, as without gaps).
  _gapDataPatch(data, symbol) {
    const alone = isolatedPoints(data);
    if (alone.size === 0 || this._lone(data)) {
      const patch = this._dataPatchOf(data, symbol);
      return patch.showSymbol ? patch : { ...patch, symbolSize: GAP_MARKER_SIZE };
    }
    return {
      data,
      showSymbol: true,
      symbol: symbol || "circle",
      symbolSize: (_value, params) => (alone.has(params.dataIndex) ? GAP_MARKER_SIZE : 0),
    };
  },

  // sampling of a drawn line: LTTB keeps one null per frame, so a line with
  // breaks (or a band) is not sampled
  _sampling(data, banded) {
    return banded || hasNull(data) ? "none" : "lttb";
  },
};
