// Setpoints (held lines): each reading holds until the next one, the last
// one to the end of the chart, and a zoomed window starts with the one in
// force.
// Methods of the EChartsChart hook (see ./echarts_chart.js).

export const Setpoints = {
  // A setpoint holds until the next one: draw its last reading on to now
  // (live) or to the newest reading of any series (history). Only the drawn
  // copy gets the extra point; the buffer keeps the real readings.
  _heldTarget(data, allSeries) {
    if (!data || data.length === 0) return data;
    const last = data[data.length - 1];
    const lastTs = this._pointTs(last);
    let end = null;
    if (Array.isArray(this._rangeButtons)) {
      end = Date.now();
    } else {
      const all = allSeries ? allSeries.map((s) => (s && s.data) || []) : Object.values(this._seriesData || {});
      all.forEach((d) => {
        const ts = d.length ? this._pointTs(d[d.length - 1]) : null;
        if (ts != null && (end === null || ts > end)) end = ts;
      });
    }
    const held = end === null || lastTs == null || end <= lastTs ? data : data.concat([[end, this._pointValue(last)]]);
    return this._pinToWindow(held);
  },

  // A zoomed history plot drops every point outside the window (filterMode
  // "filter"), and a setpoint has only a few readings: the one in force at
  // an edge would vanish with its line. Repeat it at both edges.
  _pinToWindow(data) {
    if (!this._windowFetch || data.length === 0) return data;
    const win = this._visibleWindow();
    if (!win) return data;
    const [lo, hi] = win;
    const out = [];
    let prev = null;
    data.forEach((p) => {
      const ts = this._pointTs(p);
      if (prev) {
        const prevTs = this._pointTs(prev);
        if (prevTs < lo && ts > lo) out.push([lo, this._pointValue(prev)]);
        if (prevTs < hi && ts > hi) out.push([hi, this._pointValue(prev)]);
      }
      out.push(p);
      prev = p;
    });
    return out;
  },

  // series patch that redraws only the setpoint lines, or null if none
  _targetSeriesPatch() {
    if (!this._chart || !this._targetIdx || this._targetIdx.size === 0) return null;
    const map = this._seriesMap || Object.keys(this._seriesData).map((src) => ({ src, elem: null }));
    return map.map(({ src, elem, band }) =>
      !band && elem == null && this._targetIdx.has(String(src)) ? { data: this._drawnData(src) } : {},
    );
  },

  _drawnData(idx) {
    const d = this._seriesData[idx];
    return this._targetIdx && this._targetIdx.has(String(idx)) ? this._heldTarget(d) : d;
  },
};
