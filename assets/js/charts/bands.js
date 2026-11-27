// The min/mean/max band of history number lines, and its on/off toggle.
// Methods of the EChartsChart hook (see ./echarts_chart.js).

import {
  CHART_PALETTE,
  escHtml,
  formatAxisNumber,
  isDarkTheme,
  readBandPref,
  writeBandPref,
} from "./common";
import { breakRows } from "./gaps.mjs";

export const Bands = {
  // payloads by series index: {bucket_ms, from, until, rows}
  _envelopesBySeries(list) {
    const out = {};
    (list || []).forEach((e) => {
      if (e && e.seriesIndex != null) out[e.seriesIndex] = e;
    });
    return out;
  },

  // --- Band (min/mean/max per bucket) ---------------------------------------
  // The server puts each bucket's mean into the line and sends the band
  // rows apart (per series: [t, min, mean, max]). Overview rows show outside
  // the zoomed window, its rows inside.

  // a drawn line that can carry a band: one the server named (a Drivable's
  // `value`, not its `target`)
  _bandParent(m) {
    if (!m || m.band || m.elem != null) return false;
    return (this._envMeta.series || []).includes(m.src);
  },

  // the band the user wants for this plot right now
  _envFlag() {
    return !!this._envMeta && this._windowFetch && readBandPref();
  },

  // bands are drawn: the overview the chart shows holds an envelope
  _envActive() {
    return !!this._envMeta && this._overviewEnvelope;
  },

  // Band rows of a series as {t, min, mean, max}, overview outside the
  // zoomed window and detail inside, with a break (null) wherever one
  // segment ends and the next begins. Cached until either changes.
  _bandRowsOf(src) {
    this._bandCache = this._bandCache || {};
    if (this._bandCache[src]) return this._bandCache[src];
    const ov = (this._overviewEnvelopes[src] || {}).rows || [];
    const d = this._detail;
    const inner = d ? ((d.envelopes || {})[src] || {}).rows || [] : [];
    const segments = d ? [ov.filter((r) => r[0] < d.from), inner, ov.filter((r) => r[0] > d.to)] : [ov];
    const out = [];
    segments
      .filter((g) => g.length)
      .forEach((g, k) => {
        if (k > 0) out.push(null);
        g.forEach((r) => out.push({ t: r[0], min: r[1], mean: r[2], max: r[3] }));
      });
    // by time, for the tooltip
    this._bandCache[`${src}:at`] = new Map(out.filter(Boolean).map((r) => [r.t, r]));
    this._bandCache[src] = out;
    return out;
  },

  _hasBand(src) {
    return this._bandRowsOf(src).length > 0;
  },

  // helper series data: the lower edge, and the range stacked on it
  _bandData(src, which) {
    // a break wherever the band's line broke at a gap (./gaps.mjs)
    const rows = breakRows(this._bandRowsOf(src), this._lineBreaks(src));
    const out = [];
    rows.forEach((r, k) => {
      if (r) {
        out.push([r.t, which === "lower" ? r.min : r.max - r.min]);
      } else if (k > 0 && rows[k - 1]) {
        // a break, at the time of the row before it
        out.push([rows[k - 1].t, null]);
      }
    });
    return out;
  },

  // The band row at time t of a line, for the tooltip.
  _bandRowAt(src, t) {
    this._bandRowsOf(src);
    return this._bandCache[`${src}:at`].get(t) || null;
  },

  // Adds the band helpers to a composed option: per band line a lower
  // series and a range series stacked on it, after all other series so the
  // server's series indexes stay put. Same name as the line, so its legend
  // entry hides the band too.
  _withBands(option) {
    if (!this._envActive()) return option;
    const base = option.series || [];
    const map = this._seriesMap || base.map((_s, i) => ({ src: i, elem: null }));
    const helpers = [];
    const helperMap = [];
    map.forEach((m, j) => {
      if (!this._bandParent(m)) return;
      const parent = base[j];
      const color = CHART_PALETTE[j % CHART_PALETTE.length];
      const key = `env-${m.src}`;
      const common = {
        type: "line",
        name: parent && parent.name,
        xAxisIndex: parent && parent.xAxisIndex,
        yAxisIndex: parent && parent.yAxisIndex,
        stack: key,
        stackStrategy: "all",
        symbol: "none",
        showSymbol: false,
        lineStyle: { width: 0, opacity: 0 },
        tooltip: { show: false },
        silent: true,
        z: 1,
        animation: false,
        color,
      };
      helpers.push({ ...common, id: `${key}-lower`, data: this._bandData(m.src, "lower") });
      helpers.push({
        ...common,
        id: `${key}-range`,
        areaStyle: { color, opacity: isDarkTheme() ? 0.22 : 0.16 },
        data: this._bandData(m.src, "range"),
      });
      helperMap.push({ src: m.src, elem: null, band: "lower" }, { src: m.src, elem: null, band: "range" });
    });
    this._seriesMap = [...map, ...helperMap];
    const series = base.map((s, j) => {
      const m = map[j];
      // a line of bucket means: every mean counts, and no markers on them
      return this._bandParent(m) && this._hasBand(m.src) ? { ...s, sampling: "none", showSymbol: false } : s;
    });
    const tooltip = { ...(option.tooltip || {}), trigger: "axis", formatter: (ps) => this._envelopeTooltip(ps) };
    return { ...option, tooltip, series: [...series, ...helpers] };
  },

  // Axis tooltip of a line plot with bands: each line once, as
  // "mean (min … max)" where a bucket's band is, else its value.
  _envelopeTooltip(ps) {
    if (!ps || ps.length === 0) return "";
    const esc = escHtml;
    const fmt = (v) => (typeof v === "number" ? formatAxisNumber(v) : esc(String(v)));
    const t = ps[0].value && ps[0].value[0];
    const head = `<div>${esc(new Date(t).toLocaleString([], { hour12: false }))}</div>`;
    const seen = new Set();
    const rows = [];
    ps.forEach((p) => {
      if (seen.has(p.seriesName)) return;
      const m = (this._seriesMap || [])[p.seriesIndex];
      if (m && m.band) return;
      const v = p.value && p.value[1];
      const band = m && this._bandParent(m) ? this._bandRowAt(m.src, p.value[0]) : null;
      seen.add(p.seriesName);
      const text = band ? `${fmt(band.mean)} <span style="opacity:.7">(${fmt(band.min)} … ${fmt(band.max)})</span>` : fmt(v);
      rows.push(`<span style="color:${p.color}">●</span> ${esc(p.seriesName)} ${text}`);
    });
    return head + rows.join("<br>");
  },

  // The band switch: for historical plots with a number line.
  _renderEnvelopeToggle() {
    const el = document.getElementById(`envelope-toggle-${this.el.id}`);
    if (!el) return;
    if (!this._envMeta || !this._windowFetch) {
      el.innerHTML = "";
      return;
    }
    const on = readBandPref();
    let b = el.querySelector("button");
    if (!b) {
      el.innerHTML = "";
      b = document.createElement("button");
      b.type = "button";
      b.id = `envelope-btn-${this.el.id}`;
      b.className = "ml-1 inline-flex items-center gap-1 rounded border border-line px-2 py-0.5 text-xs transition-colors";
      const i = document.createElement("span");
      i.className = "hero-chart-bar-square-micro size-3.5";
      b.append(i, "Band");
      b.addEventListener("click", () => {
        writeBandPref(!readBandPref());
        this._onEnvFlagChange();
      });
      el.appendChild(b);
    }
    b.setAttribute("aria-pressed", String(on));
    b.title = on
      ? "Showing each interval's min–max band and mean. Click for the thinned readings."
      : "Show each interval's min–max band and mean";
    this._styleRangeButton(b, on);
  },

  // The wanted band mode changed: back to the loaded overview's mode at
  // once, or load the overview in the new mode first.
  _onEnvFlagChange() {
    if (!this._envMeta || !this._windowFetch) return;
    this._bandCache = null;
    const want = this._envFlag();
    this._envGen = (this._envGen || 0) + 1;
    this._windowReq = (this._windowReq || 0) + 1; // a window reply on its way is outdated
    if (want === this._overviewEnvelope) {
      this._reloadPending = false;
      this._detail = null;
      this._detailState = null;
      this._rebuild();
      this._fetchWindow();
    } else {
      this._reloadPending = true;
      this.pushEventTo(this.el, "fetch-chart-overview", { envelope: want, gen: this._envGen });
    }
    this._renderEnvelopeToggle();
  },
};
