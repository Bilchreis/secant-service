import * as echarts from "echarts";
import { CHART_PALETTE, ThemeWatch, escHtml, formatAxisNumber, isDarkTheme } from "./common";

// ---------------------------------------------------------------------------
// Sparkline: 10-minute trend of a module's value (and target) on the cards.
// The server sends the history once and then only new readings. Drawn with a
// small ECharts instance (SVG renderer, no axes) so hovering shows the value.
// ---------------------------------------------------------------------------

const SPARK_WINDOW_MS = 10 * 60 * 1000;
const SPARK_MAX_POINTS = 2000;

// one timer for all sparklines: keeps the time axis moving between batches
const SparkDriver = {
  _hooks: new Set(),
  _timer: null,
  add(hook) {
    this._hooks.add(hook);
    if (!this._timer)
      this._timer = setInterval(() => !document.hidden && this._hooks.forEach((h) => h._visible && h.draw()), 3000);
  },
  remove(hook) {
    this._hooks.delete(hook);
    if (this._hooks.size === 0 && this._timer) {
      clearInterval(this._timer);
      this._timer = null;
    }
  },
};

const SparkVisibility = new IntersectionObserver((entries) => {
  entries.forEach((e) => {
    const hook = e.target._sparkHook;
    if (!hook) return;
    hook._visible = e.isIntersecting;
    if (hook._visible) hook.draw();
  });
});

// Shared look of the small card charts: no axes, no animation, a compact
// tooltip appended to <body> so the card does not clip it.
function sparkBase(formatter) {
  const muted = getComputedStyle(document.documentElement).getPropertyValue("--sc-muted").trim() || "#888";
  const dark = isDarkTheme();
  return {
    muted,
    base: {
      animation: false,
      grid: { left: 1, right: 1, top: 3, bottom: 3 },
      yAxis: { type: "value", scale: true, show: false, splitLine: { show: false } },
      tooltip: {
        trigger: "axis",
        appendTo: "body",
        transitionDuration: 0,
        padding: [4, 8],
        backgroundColor: dark ? "#1f1f22" : "#ffffff",
        borderColor: dark ? "#333336" : "#d4d4d8",
        textStyle: { fontSize: 11, color: dark ? "#e4e4e7" : "#27272a" },
        axisPointer: { type: "line", lineStyle: { color: muted, width: 1, type: "dashed" } },
        formatter,
      },
    },
  };
}

// y range from the data; a flat line sits in the middle
function sparkRange(lo, hi) {
  const pad = hi === lo ? Math.abs(lo) * 0.1 || 1 : 0;
  return { min: lo - pad, max: hi + pad };
}

// Smallest y span a card trend shows: 2 % of the datainfo range, or 1 % of
// the reading's size when the range is unknown. Changes smaller than that
// (usually noise) stay small instead of being zoomed to full height.
const SPARK_SPAN_OF_LIMITS = 0.02;
const SPARK_SPAN_OF_VALUE = 0.01;

function sparkFloorRange(lo, hi, limMin, limMax) {
  const hasLimits = limMin !== null && limMax !== null && limMax > limMin;
  const floor = hasLimits
    ? (limMax - limMin) * SPARK_SPAN_OF_LIMITS
    : Math.max(Math.abs(lo), Math.abs(hi)) * SPARK_SPAN_OF_VALUE;
  if (!(floor > 0) || hi - lo >= floor) return sparkRange(lo, hi);

  // widen around the data, but stay inside the limits so a reading resting
  // at a bound (e.g. 0 flow) draws along the edge, not mid-card
  let min = (lo + hi - floor) / 2;
  let max = min + floor;
  if (limMin !== null && min < limMin && lo >= limMin) {
    min = limMin;
    max = limMin + floor;
  } else if (limMax !== null && max > limMax && hi <= limMax) {
    max = limMax;
    min = limMax - floor;
  }
  return { min, max };
}

function sparkTime(ms) {
  const d = new Date(ms);
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

export const Sparkline = {
  mounted() {
    this.series = { value: [], target: [] };
    this.skew = 0; // node clock minus browser clock, from the newest readings
    this._visible = true;
    this.unit = this.el.dataset.unit || "";
    const lim = (k) => (this.el.dataset[k] === undefined || this.el.dataset[k] === "" ? null : Number(this.el.dataset[k]));
    this.limMin = lim("min");
    this.limMax = lim("max");
    this.box = this.el.querySelector("[data-role=chart]");
    this.empty = this.el.querySelector("[data-role=empty]");

    this.handleEvent(`spark-init-${this.el.id}`, (history) => {
      ["value", "target"].forEach((s) => {
        const hist = history[s] || [];
        const lastT = hist.length ? hist[hist.length - 1][0] : -Infinity;
        // keep live readings that arrived while the history was loading
        this.series[s] = hist.concat(this.series[s].filter((p) => p[0] > lastT));
      });
      if (this._visible) this.draw();
    });

    this.handleEvent(`spark-add-${this.el.id}`, ({ s, p }) => {
      if (!this.series[s] || p.length === 0) return;
      this.series[s].push(...p);
      if (this.series[s].length > SPARK_MAX_POINTS) this.series[s] = this.series[s].slice(-SPARK_MAX_POINTS);
      this.skew = p[p.length - 1][0] - Date.now();
      if (this._visible) this.draw();
    });

    this._onThemeChange = () => {
      if (!this.chart) return;
      this.chart.dispose();
      this.chart = null;
      this.draw();
    };
    ThemeWatch.add(this._onThemeChange);
    this._resize = new ResizeObserver(() => this.chart && this.chart.resize());
    this._resize.observe(this.box);

    this.el._sparkHook = this;
    SparkVisibility.observe(this.el);
    SparkDriver.add(this);
    this.pushEventTo(this.el, "spark-ready", {});
  },

  reconnected() {
    // the server side starts over after a reconnect and waits for this
    this.pushEventTo(this.el, "spark-ready", {});
  },

  destroyed() {
    SparkDriver.remove(this);
    SparkVisibility.unobserve(this.el);
    ThemeWatch.remove(this._onThemeChange);
    this._resize && this._resize.disconnect();
    this.chart && this.chart.dispose();
    this.chart = null;
  },

  // created on first draw with data, so cards off screen or without readings
  // cost nothing
  _ensureChart() {
    if (this.chart) return this.chart;
    if (!this.box.clientWidth) return null;
    const { muted, base } = sparkBase((items) => this._tooltip(items));
    this.chart = echarts.init(this.box, null, { renderer: "svg" });
    this.chart.setOption({
      ...base,
      xAxis: { type: "time", show: false },
      series: [
        {
          name: "value",
          type: "line",
          step: "end",
          showSymbol: false,
          symbolSize: 5,
          lineStyle: { width: 1.5, color: CHART_PALETTE[0] },
          itemStyle: { color: CHART_PALETTE[0] },
          emphasis: { disabled: true },
          data: [],
        },
        {
          name: "target",
          type: "line",
          step: "end",
          showSymbol: false,
          symbolSize: 4,
          lineStyle: { width: 1, type: [3, 2], color: muted },
          itemStyle: { color: muted },
          emphasis: { disabled: true },
          data: [],
        },
      ],
    });
    return this.chart;
  },

  // value and target in force at the hovered time (each reading holds until
  // the next), not just the readings that happen to lie under the cursor
  _tooltip(items) {
    if (!items.length) return "";
    const t = items[0].axisValue;
    const at = (points) => {
      let lo = 0;
      let hi = points.length - 1;
      if (hi < 0 || points[0][0] > t) return null;
      while (lo < hi) {
        const mid = (lo + hi + 1) >> 1;
        if (points[mid][0] <= t) lo = mid;
        else hi = mid - 1;
      }
      return points[lo][1];
    };
    const fmt = (v) => `${formatAxisNumber(v)}${this.unit ? ` ${escHtml(this.unit)}` : ""}`;
    const row = (label, v) =>
      v === null
        ? ""
        : `<div style="display:flex;justify-content:space-between;gap:12px">` +
          `<span style="opacity:.7">${label}</span><b style="font-variant-numeric:tabular-nums">${fmt(v)}</b></div>`;
    return (
      `<div style="opacity:.7;margin-bottom:2px">${sparkTime(t)}</div>` +
      row("value", at(this.series.value)) +
      row("target", at(this.series.target))
    );
  },

  // drop readings that left the window, but keep the last one before it so
  // the line still starts at the left edge
  _trim(points, cutoff) {
    let i = 0;
    while (i < points.length - 1 && points[i + 1][0] < cutoff) i++;
    return i > 0 ? points.slice(i) : points;
  },

  draw() {
    const now = Date.now() + this.skew;
    const cutoff = now - SPARK_WINDOW_MS;
    this.series.value = this._trim(this.series.value, cutoff);
    this.series.target = this._trim(this.series.target, cutoff);
    const { value, target } = this.series;

    this.empty.style.display = value.length ? "none" : "";
    this.box.style.visibility = value.length ? "" : "hidden";
    if (value.length === 0) return;
    const chart = this._ensureChart();
    if (!chart) return;

    // x spans 10 minutes, or less while there is less data (fresh node)
    const start = Math.max(cutoff, Math.min(value[0][0], now - 60_000));
    // each reading holds until the next one, the last one until now
    const held = (points) => (points.length ? points.concat([[now, points[points.length - 1][1]]]) : []);
    // tight y range from the data (ECharts' own range rounds outward and
    // leaves a flat line at the bottom), but never narrower than a floor, so
    // a steady reading with noise draws as a nearly flat line
    let lo = Infinity;
    let hi = -Infinity;
    for (const p of value.concat(target)) {
      if (p[1] < lo) lo = p[1];
      if (p[1] > hi) hi = p[1];
    }
    const flat = hi === lo;

    chart.setOption({
      xAxis: { min: start, max: now },
      yAxis: sparkFloorRange(lo, hi, this.limMin, this.limMax),
      series: [
        { data: held(value), lineStyle: { opacity: flat ? 0.4 : 1 } },
        { data: held(target) },
      ],
    });
  },
};

// ---------------------------------------------------------------------------
// ArraySpark: latest reading of a numeric array on the cards, plotted against
// index. The server sends thinned [index, value] points in data-points and
// replaces the attribute with each reading; hovering shows index and value.
// ---------------------------------------------------------------------------

const ArraySparkVisibility = new IntersectionObserver((entries) => {
  entries.forEach((e) => {
    const hook = e.target._arraySparkHook;
    if (!hook) return;
    hook._visible = e.isIntersecting;
    if (hook._visible && hook._stale) hook.draw();
  });
});

export const ArraySpark = {
  mounted() {
    this._visible = true;
    this._stale = true;
    this._onThemeChange = () => {
      if (!this.chart) return;
      this.chart.dispose();
      this.chart = null;
      this._stale = true;
      this.draw();
    };
    ThemeWatch.add(this._onThemeChange);
    this._resize = new ResizeObserver(() => (this.chart ? this.chart.resize() : this._stale && this.draw()));
    this._resize.observe(this.el);
    this.el._arraySparkHook = this;
    ArraySparkVisibility.observe(this.el);
    this.draw();
  },

  // the server patched data-points with a new reading
  updated() {
    this._stale = true;
    if (this._visible) this.draw();
  },

  destroyed() {
    ThemeWatch.remove(this._onThemeChange);
    ArraySparkVisibility.unobserve(this.el);
    this._resize && this._resize.disconnect();
    this.chart && this.chart.dispose();
    this.chart = null;
  },

  _ensureChart() {
    if (this.chart) return this.chart;
    if (!this.box) this.box = this.el.querySelector("[data-role=chart]") || this.el;
    if (!this.box.clientWidth) return null;
    const { base } = sparkBase((items) => {
      const it = items[0];
      if (!it) return "";
      const [i, v] = it.value;
      const unit = this.el.dataset.unit;
      return `<span style="opacity:.7">[${i}]</span> <b style="font-variant-numeric:tabular-nums">${formatAxisNumber(v)}${unit ? ` ${escHtml(unit)}` : ""}</b>`;
    });
    this.chart = echarts.init(this.box, null, { renderer: "svg" });
    this.chart.setOption({
      ...base,
      xAxis: { type: "value", show: false },
      series: [
        {
          type: "line",
          showSymbol: false,
          symbolSize: 5,
          lineStyle: { width: 1.5, color: CHART_PALETTE[0] },
          itemStyle: { color: CHART_PALETTE[0] },
          emphasis: { disabled: true },
          data: [],
        },
      ],
    });
    return this.chart;
  },

  draw() {
    let points;
    try {
      points = JSON.parse(this.el.dataset.points || "[]");
    } catch (_e) {
      points = [];
    }
    if (points.length === 0) return;
    const chart = this._ensureChart();
    if (!chart) return;
    this._stale = false;

    let lo = Infinity;
    let hi = -Infinity;
    for (const p of points) {
      if (p[1] < lo) lo = p[1];
      if (p[1] > hi) hi = p[1];
    }
    const n = Number(this.el.dataset.n) || points.length;
    chart.setOption({
      xAxis: { min: 0, max: Math.max(n - 1, 1) },
      yAxis: sparkRange(lo, hi),
      series: [{ data: points, lineStyle: { opacity: hi === lo ? 0.4 : 1 } }],
    });
  },
};
