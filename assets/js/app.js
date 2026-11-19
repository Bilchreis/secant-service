// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/secant_service";
import topbar from "../vendor/topbar";

import * as echarts from "echarts";
import { pointTs, trimBefore, withTail } from "./chart_series";

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

const maxPoints = 20000;
// How often a live line chart redraws just to carry its last value up to "now"
const TAIL_REFRESH_MS = 5000;
// array plots buffer one point per element per reading
const maxArrayPoints = 400000;

// Heatmap / Lines for 1-D array plots, remembered per browser.
const ARRAY_MODE_KEY = "secant:array-mode";
const readArrayMode = () => {
  try {
    return localStorage.getItem(ARRAY_MODE_KEY) === "lines" ? "lines" : "heatmap";
  } catch (_e) {
    return "heatmap";
  }
};

// Line colours for array elements: index 0 → violet … last → rose, so the
// order reads at a glance; all stops stay visible on light and dark.
const ARRAY_LINE_STOPS = [
  [139, 92, 246],
  [56, 189, 248],
  [16, 185, 129],
  [245, 158, 11],
  [244, 63, 94],
];
// Text from the node's description (units, names) going into tooltip HTML.
function escHtml(v) {
  return String(v).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

// Axis and scale labels that stay readable for tiny or huge values
// (e.g. partial pressures of 1e-13 mbar): exponent form outside 1e-3 … 1e6.
function formatAxisNumber(v) {
  if (typeof v !== "number" || !isFinite(v)) return String(v);
  if (v === 0) return "0";
  const a = Math.abs(v);
  if (a < 1e-3 || a >= 1e6) {
    const [m, e] = v.toExponential(2).split("e");
    return `${Number(m)}e${Number(e)}`;
  }
  return String(Number(v.toPrecision(4)));
}

function arrayLineColor(i, n) {
  if (n <= 1) return "rgb(139, 92, 246)";
  const x = (i / (n - 1)) * (ARRAY_LINE_STOPS.length - 1);
  const k = Math.min(Math.floor(x), ARRAY_LINE_STOPS.length - 2);
  const f = x - k;
  const a = ARRAY_LINE_STOPS[k];
  const b = ARRAY_LINE_STOPS[k + 1];
  return `rgb(${a.map((v, j) => Math.round(v + (b[j] - v) * f)).join(", ")})`;
}

// Single shared timer driving all mounted EChartsChart flushes, instead of
// one setInterval per chart — keeps per-tick cost bounded/coordinated rather
// than scaling with the number of plots on the page.
const ChartFlushDriver = {
  _instances: new Set(),
  _timer: null,
  register(hook) {
    this._instances.add(hook);
    if (!this._timer) this._timer = setInterval(() => this._tick(), 1000);
  },
  unregister(hook) {
    this._instances.delete(hook);
    if (this._instances.size === 0 && this._timer) {
      clearInterval(this._timer);
      this._timer = null;
    }
  },
  _tick() {
    for (const hook of this._instances) {
      try {
        hook._flushBuffer();
      } catch (error) {
        console.error("ECharts flush error:", error);
      }
    }
  },
};

// Single shared IntersectionObserver so fully off-screen charts skip their
// setOption work entirely (data keeps buffering; the next visible tick
// recomputes everything correctly from current state, so no catch-up logic
// is needed).
const ChartVisibilityObserver = new IntersectionObserver((entries) => {
  entries.forEach((entry) => {
    if (entry.target._echartsHook) {
      entry.target._echartsHook._isVisible = entry.isIntersecting;
    }
  });
});

// ---------------------------------------------------------------------------
// Theme helpers: charts follow the light/dark theme of the page
// ---------------------------------------------------------------------------

const prefersDark = window.matchMedia("(prefers-color-scheme: dark)");

function isDarkTheme() {
  const theme = document.documentElement.getAttribute("data-theme");
  if (theme === "dark") return true;
  if (theme === "light") return false;
  return prefersDark.matches;
}

// Series palette: violet accent first, then colours that stay apart in both
// themes (and differ in lightness, not only hue).
const CHART_PALETTE = ["#8b5cf6", "#38bdf8", "#f59e0b", "#10b981", "#f43f5e", "#a3a3a8", "#ec4899", "#84cc16"];

// Notify mounted charts when the theme changes (theme toggle or OS setting).
const ThemeWatch = {
  _listeners: new Set(),
  add(fn) { this._listeners.add(fn); },
  remove(fn) { this._listeners.delete(fn); },
  _fire() { this._listeners.forEach((fn) => fn()); },
};
new MutationObserver(() => ThemeWatch._fire()).observe(document.documentElement, {
  attributes: true,
  attributeFilter: ["data-theme"],
});
prefersDark.addEventListener("change", () => ThemeWatch._fire());

// Width of the module inspector, remembered per browser.
const INSPECTOR_KEY = "secant:inspector-width";
const INSPECTOR_MIN = 320;
// Leave room for the module rail and one narrow column of cards; the panel
// may take everything else. CSS caps it the same way on window resize.
// From xl the rail (15rem) is shown too; between lg and xl it is hidden.
const inspectorReserved = () => (window.innerWidth >= 1280 ? 544 : 288); // 34rem / 18rem
const inspectorMax = () => Math.max(INSPECTOR_MIN, window.innerWidth - inspectorReserved());
try {
  const saved = parseInt(localStorage.getItem(INSPECTOR_KEY), 10);
  if (saved >= INSPECTOR_MIN) {
    document.documentElement.style.setProperty("--inspector-w", `${saved}px`);
  }
} catch (_e) {
  // storage unavailable (private mode): keep the CSS default
}

let Hooks = {};

// Drag handle on the left edge of the inspector panel. The width is kept in a
// CSS variable on <html>, outside the LiveView DOM, so patches never reset it.
Hooks.ResizablePanel = {
  mounted() {
    const panel = this.el.parentElement;
    const setWidth = (w) => {
      const width = Math.round(Math.min(inspectorMax(), Math.max(INSPECTOR_MIN, w)));
      document.documentElement.style.setProperty("--inspector-w", `${width}px`);
      return width;
    };
    const save = (w) => {
      try { localStorage.setItem(INSPECTOR_KEY, String(w)); } catch (_e) {}
    };

    this._onDown = (e) => {
      e.preventDefault();
      const startX = e.clientX;
      const startW = panel.getBoundingClientRect().width;
      let last = startW;
      this.el.setPointerCapture(e.pointerId);
      document.body.style.userSelect = "none";
      const move = (ev) => { last = setWidth(startW + (startX - ev.clientX)); };
      const up = () => {
        this.el.removeEventListener("pointermove", move);
        this.el.removeEventListener("pointerup", up);
        this.el.removeEventListener("pointercancel", up);
        document.body.style.userSelect = "";
        save(last);
      };
      this.el.addEventListener("pointermove", move);
      this.el.addEventListener("pointerup", up);
      this.el.addEventListener("pointercancel", up);
    };
    this._onDblClick = () => {
      document.documentElement.style.removeProperty("--inspector-w");
      try { localStorage.removeItem(INSPECTOR_KEY); } catch (_e) {}
    };
    this._onKey = (e) => {
      if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
      e.preventDefault();
      const step = e.shiftKey ? 80 : 20;
      const w = panel.getBoundingClientRect().width + (e.key === "ArrowLeft" ? step : -step);
      save(setWidth(w));
    };
    this.el.addEventListener("pointerdown", this._onDown);
    this.el.addEventListener("dblclick", this._onDblClick);
    this.el.addEventListener("keydown", this._onKey);
  },
  destroyed() {
    this.el.removeEventListener("pointerdown", this._onDown);
    this.el.removeEventListener("dblclick", this._onDblClick);
    this.el.removeEventListener("keydown", this._onKey);
  },
};

Hooks.EChartsChart = {
  mounted() {
    // seriesIndex → [[ts, val], ...]  — maintained across flushes for windowing
    this._seriesData = {};
    this._rangeButtons = null;
    this._activeButton = null;
    this._pendingOption = null; // buffered if server data arrives before chart is ready
    this._arrayLen = null; // non-null for 1-D array plots; drives yAxis.max updates
    this._arrayUnit = null;
    this._arrayName = null;
    this._arrayLatest = null; // {t, n, shown, unit} for long arrays: latest reading only
    this._arrayMode = readArrayMode(); // "heatmap" | "lines"
    this._heatCache = {}; // seriesIndex → painted grid, for the hover readout
    this._visualMapMin = null; // running min/max for heatmap color scale
    this._visualMapMax = null;
    this._xAxisCount = 1; // >1 for multi-grid charts (struct subplots)
    this._dataDirty = false; // true when _seriesData changed since the last flush
    this._isVisible = true; // updated by ChartVisibilityObserver; default true pre-observation

    ChartFlushDriver.register(this);
    this.el._echartsHook = this;
    ChartVisibilityObserver.observe(this.el);

    // Register handlers immediately — server may send data before rAF fires (eager push)
    this.handleEvent(`echarts-data-${this.el.id}`, ({ option }) => {
      const { _rangeButtons, _activeButton, _arrayLen, _arrayUnit, _arrayName, _arrayLatest, _arrayTimes, ...echartsOption } = option;
      this._rangeButtons = _rangeButtons || null;
      this._activeButton = _activeButton != null ? _activeButton : null;
      this._arrayLen = _arrayLen != null ? _arrayLen : null;
      this._arrayUnit = _arrayUnit || null;
      this._arrayName = _arrayName || null;
      this._arrayLatest = _arrayLatest || null;
      this._arrayTimes = Array.isArray(_arrayTimes) ? _arrayTimes : null;
      this._scrubIndex = null; // null = follow the latest reading
      this._wantT = null;
      // the starting reading may not be in the database yet either: cache it
      // like a live one so "latest" on the slider finds it
      this._liveReadings = new Map();
      if (_arrayLatest && _arrayLatest.t != null) {
        const { unit: _u, ...info } = _arrayLatest;
        this._liveReadings.set(_arrayLatest.t, { ...info, data: (echartsOption.series?.[0]?.data) || [] });
      }

      this._seriesData = {};
      this._visualMapMin = null;
      this._visualMapMax = null;
      this._xAxisCount = Array.isArray(echartsOption.xAxis) ? echartsOption.xAxis.length : 1;
      (echartsOption.series || []).forEach((s, i) => {
        this._seriesData[i] = s.data || [];
      });
      // Seed min/max from initial data and bake into the option (visualMap present = heatmap)
      if (echartsOption.visualMap) {
        for (const p of (this._seriesData[0] || [])) {
          const v = p[2];
          if (this._visualMapMin === null || v < this._visualMapMin) this._visualMapMin = v;
          if (this._visualMapMax === null || v > this._visualMapMax) this._visualMapMax = v;
        }
        if (this._visualMapMin !== null) {
          const vMax = this._visualMapMax === this._visualMapMin ? this._visualMapMax + 1 : this._visualMapMax;
          if (Array.isArray(echartsOption.visualMap)) {
            echartsOption.visualMap = echartsOption.visualMap.map((vm, i) =>
              i === 0 ? { ...vm, min: this._visualMapMin, max: vMax } : vm
            );
          } else {
            echartsOption.visualMap = { ...echartsOption.visualMap, min: this._visualMapMin, max: vMax };
          }
        }
      }

      if (this._chart) {
        this._applyInitialOption(echartsOption);
      } else {
        this._pendingOption = echartsOption;
      }
    });

    // reading picked with the time slider
    this.handleEvent(`array-reading-${this.el.id}`, (snapshot) => {
      // only the reading asked for last (the slider may have moved on)
      if (snapshot.requested !== this._wantT) return;
      this._wantT = null;
      this._applySnapshot(snapshot);
      this._renderScrub();
    });

    this.handleEvent("chart-update", ({ option }) => {
      const { _rangeButtons, _activeButton, _arrayLen, _arrayUnit, _arrayName, _arrayLatest, _arrayTimes, ...echartsOption } = option;
      this._lastOption = echartsOption;
      this._chart && this._chart.setOption(this._themed(echartsOption), { notMerge: true });
    });

    this.handleEvent(`prepend-chart-data-${this.el.id}`, ({ seriesUpdates, arrayLen }) => {
      (seriesUpdates || []).forEach(({ seriesIndex, data }) => {
        if (!this._seriesData[seriesIndex]) this._seriesData[seriesIndex] = [];
        this._seriesData[seriesIndex] = [...data, ...this._seriesData[seriesIndex]];
        if (this._arrayLen != null && seriesIndex === 0) this._trackHeatRange(data);
      });
      this._growArrayLen(arrayLen);
      this._dataDirty = true;
    });

    this.handleEvent(`extend-chart-${this.el.id}`, ({ seriesUpdates, arrayLen, snapshot }) => {
      if (snapshot) {
        // a new reading: add it to the slider; show it only when following
        if (this._arrayTimes && snapshot.t != null && snapshot.t > (this._arrayTimes[this._arrayTimes.length - 1] ?? -Infinity)) {
          this._arrayTimes.push(snapshot.t);
        }
        // recent readings may not be in the database yet (writes are batched):
        // keep the last few here so the slider can show them
        if (snapshot.t != null) {
          this._liveReadings = this._liveReadings || new Map();
          this._liveReadings.set(snapshot.t, snapshot);
          if (this._liveReadings.size > 30) this._liveReadings.delete(this._liveReadings.keys().next().value);
        }
        if (this._scrubIndex == null) {
          // a DB reply still on its way is older than this reading
          this._wantT = null;
          this._applySnapshot(snapshot);
        }
        this._renderScrub();
        return;
      }
      (seriesUpdates || []).forEach(({ seriesIndex, data }) => {
        if (!this._seriesData[seriesIndex]) this._seriesData[seriesIndex] = [];
        this._seriesData[seriesIndex].push(...data);
        // running min/max of the heatmap values
        if (this._arrayLen != null && seriesIndex === 0) this._trackHeatRange(data);
      });
      this._growArrayLen(arrayLen);
      this._dataDirty = true;
    });

    this._toggleRangeslider = (e) => {
      if (e.target.dataset.chartId !== this.el.id || !this._chart) return;
      const currentOption = this._chart.getOption();
      const zooms = (currentOption.dataZoom || [])
        .filter(Boolean)
        .map((dz) => ({ type: dz.type, xAxisIndex: 0 }));
      const hasSlider = zooms.some((dz) => dz.type === "slider");
      const nextZooms = hasSlider
        ? zooms.filter((dz) => dz.type !== "slider")
        : [...zooms, { type: "slider", xAxisIndex: 0, bottom: 8 }];
      const update = { dataZoom: nextZooms };
      // make room below the time axis so the slider doesn't cover its labels
      if (this._xAxisCount === 1) update.grid = { bottom: hasSlider ? 40 : 80 };
      this._chart.setOption(update, { replaceMerge: ["dataZoom"] });
    };
    document.addEventListener("toggle-rangeslider", this._toggleRangeslider);

    this.handleEvent("cleanup-charts", () => {
      this.destroyed();
    });

    this._onCloseModal = () => {
      if (this.el.closest("dialog")) {
        this._disposeChart();
      }
    };
    window.addEventListener("myapp:close-modal", this._onCloseModal);

    // Defer echarts.init until after paint so clientWidth/clientHeight are non-zero
    this._onThemeChange = () => this._reinitForTheme();
    ThemeWatch.add(this._onThemeChange);

    requestAnimationFrame(() => {
      if (!this.el) return;
      this._chart = this._initChart();

      this._resizeObserver = new ResizeObserver(() => {
        this._chart && this._chart.resize();
      });
      this._resizeObserver.observe(this.el);

      // Apply option that arrived before the chart was ready
      if (this._pendingOption) {
        this._applyInitialOption(this._pendingOption);
        this._pendingOption = null;
      } else {
        // Normal path: request data now that chart is initialized
        this.pushEventTo(this.el, "request-chart-data", { id: this.el.id });
      }
    });
  },

  _initChart() {
    return echarts.init(this.el, isDarkTheme() ? "dark" : null, { renderer: "canvas" });
  },

  // Page colours on top of the server-built option: transparent background,
  // theme text colour and the accent palette.
  _themed(option) {
    // time axes: drop labels that would overlap in narrow panels
    const fixAxis = (ax) =>
      ax && ax.type === "time"
        ? { ...ax, axisLabel: { hideOverlap: true, ...(ax.axisLabel || {}) } }
        : ax;
    // axis text, axis lines and grid lines in the page's muted and line colours
    const css = getComputedStyle(document.documentElement);
    const muted = css.getPropertyValue("--sc-muted").trim() || undefined;
    const line = css.getPropertyValue("--sc-line").trim() || undefined;
    const tint = (ax) =>
      ax && {
        ...ax,
        axisLabel: { color: muted, ...(ax.axisLabel || {}) },
        nameTextStyle: { color: muted, ...(ax.nameTextStyle || {}) },
        axisLine: { ...(ax.axisLine || {}), lineStyle: { color: line, ...((ax.axisLine || {}).lineStyle || {}) } },
        splitLine: { ...(ax.splitLine || {}), lineStyle: { color: line, ...((ax.splitLine || {}).lineStyle || {}) } },
      };
    const mapAxes = (a, f) => (Array.isArray(a) ? a.map(f) : f(a));
    const xAxis = mapAxes(option.xAxis, (ax) => tint(fixAxis(ax)));
    // array index axes: whole-number labels only (the axis runs -0.5 … n-0.5)
    const heatAxes = new Set(
      (option.series || []).filter((s) => s && s._arrayHeat).map((s) => s.yAxisIndex || 0),
    );
    const intLabels = (ax, i) =>
      heatAxes.has(i || 0)
        ? { ...ax, axisLabel: { ...(ax.axisLabel || {}), formatter: (v) => (Number.isInteger(v) ? String(v) : "") } }
        : ax;
    const yAxis = Array.isArray(option.yAxis)
      ? option.yAxis.map((ax, i) => tint(intLabels(ax, i)))
      : option.yAxis && tint(intLabels(option.yAxis, 0));
    const inactive = isDarkTheme() ? "#6b6b70" : "#9a9aa0";
    const live = Array.isArray(this._rangeButtons);
    const series = (option.series || []).map((s, i) => {
      if (s && s._enumBand) return this._enumBand(s, live);
      if (s && s._arrayHeat) return this._arrayHeat(s, live, i);
      return s;
    });
    const legend = mapAxes(
      option.legend,
      (l) => l && { inactiveColor: inactive, ...l, textStyle: { color: muted, ...(l.textStyle || {}) } },
    );
    // colour scale labels for array heatmaps
    const visualMap =
      heatAxes.size > 0 && option.visualMap
        ? mapAxes(option.visualMap, (vm) => vm && { formatter: formatAxisNumber, ...vm })
        : option.visualMap;
    return {
      color: CHART_PALETTE,
      ...option,
      ...(visualMap ? { visualMap } : {}),
      ...(xAxis ? { xAxis } : {}),
      ...(yAxis ? { yAxis } : {}),
      ...(legend ? { legend } : {}),
      series,
      backgroundColor: "transparent",
      textStyle: { fontFamily: "JetBrains Mono, ui-monospace, monospace", color: muted, ...(option.textStyle || {}) },
    };
  },

  // Enum states as continuous bands: each reading holds until the next one
  // (and, on live charts, until now). Colour comes from the point's itemStyle.
  _enumBand(series, live) {
    return {
      ...series,
      renderItem: (params, api) => {
        const i = params.dataIndexInside;
        const t0 = api.value(0);
        const y = api.value(1);
        const next = i + 1 < params.dataInsideLength ? api.value(0, i + 1) : live ? Date.now() : t0;
        const p0 = api.coord([t0, y]);
        const p1 = api.coord([next, y]);
        const band = api.size([0, 1])[1];
        const h = Math.max(6, Math.min(18, (band || 30) * 0.6));
        const rect = echarts.graphic.clipRectByRect(
          // +1 px overlap so neighbouring segments show no seam
          { x: p0[0], y: p0[1] - h / 2, width: Math.max(p1[0] - p0[0] + 1, 2), height: h },
          {
            x: params.coordSys.x,
            y: params.coordSys.y,
            width: params.coordSys.width,
            height: params.coordSys.height,
          },
        );
        return rect && { type: "rect", shape: rect, style: { fill: api.visual("color") } };
      },
    };
  },

  // 1-D arrays as a time × index heatmap. Each reading's row of cells holds
  // until the next reading (and, on live charts, until now). Thousands of
  // cells are painted onto one canvas image instead of one shape per cell;
  // colours still come from the visualMap, so its range handles filter them.
  _arrayHeat(series, live, seriesIndex) {
    const canvas = document.createElement("canvas");
    return {
      ...series,
      renderItem: (params, api) => {
        if (params.dataIndexInside !== 0) return null;
        const n = params.dataInsideLength;
        const cs = params.coordSys;
        const dpr = api.getDevicePixelRatio();
        canvas.width = Math.max(1, Math.round(cs.width * dpr));
        canvas.height = Math.max(1, Math.round(cs.height * dpr));
        const ctx = canvas.getContext("2d");
        ctx.setTransform(dpr, 0, 0, dpr, -cs.x * dpr, -cs.y * dpr);
        ctx.clearRect(cs.x, cs.y, cs.width, cs.height);

        // readings: [first item, timestamp] in time order
        const starts = [];
        const times = [];
        for (let j = 0; j < n; j++) {
          const t = api.value(0, j);
          if (j === 0 || t !== times[times.length - 1]) {
            starts.push(j);
            times.push(t);
          }
        }
        const g = times.length;
        // the last reading holds until now (live) or for one typical interval
        const lastSpan = g > 1 ? times[g - 1] - times[g - 2] : 1000;
        const ends = times.map((t, k) => (k + 1 < g ? times[k + 1] : live ? Math.max(Date.now(), t) : t + lastSpan));

        const rowH = Math.abs(api.size([0, 1])[1]) || 1;
        for (let k = 0; k < g; k++) {
          const x0 = api.coord([times[k], 0])[0];
          const x1 = api.coord([ends[k], 0])[0];
          if (x1 < cs.x || x0 > cs.x + cs.width) continue;
          // +0.5 px overlap so neighbouring cells show no seam
          const w = Math.max(x1 - x0 + 0.5, 1);
          const stop = k + 1 < g ? starts[k + 1] : n;
          for (let j = starts[k]; j < stop; j++) {
            const color = api.visual("color", j);
            if (!color) continue;
            ctx.fillStyle = color;
            const y = api.coord([times[k], api.value(1, j)])[1];
            ctx.fillRect(x0, y - rowH / 2, w, rowH + 0.5);
          }
        }

        this._heatCache[seriesIndex] = { times, ends, starts, n, api };
        return {
          type: "image",
          silent: true,
          style: { image: canvas, x: cs.x, y: cs.y, width: cs.width, height: cs.height },
        };
      },
    };
  },

  // Hover readout for heatmaps: time, index and value of the cell under the
  // pointer (a canvas image has no per-cell tooltip of its own).
  _bindHeatTooltip() {
    if (this._heatTipBound || !this._chart) return;
    this._heatTipBound = true;
    // lines mode: remember which array element's line is under the pointer,
    // so the tooltip can show just that one
    this._hoverSeries = null;
    // ECharts keeps the axis tooltip's text while the pointer stays at the
    // same time; hide and re-show it so the formatter runs again
    const retip = (p) => {
      const ev = p.event && p.event.event;
      if (!ev) return;
      this._chart.dispatchAction({ type: "hideTip" });
      this._chart.dispatchAction({ type: "showTip", x: ev.offsetX, y: ev.offsetY });
    };
    this._chart.on("mouseover", { seriesType: "line" }, (p) => {
      this._hoverSeries = p.seriesIndex;
      retip(p);
    });
    this._chart.on("mouseout", { seriesType: "line" }, (p) => {
      this._hoverSeries = null;
      retip(p);
    });
    const zr = this._chart.getZr();
    const hide = () => this._heatTip && (this._heatTip.style.display = "none");
    zr.on("mousemove", (e) => {
      const hit = this._heatCellAt(e.offsetX, e.offsetY);
      if (!hit) return hide();
      if (!this._heatTip || !this._heatTip.isConnected) {
        this._heatTip = document.createElement("div");
        this._heatTip.className =
          "pointer-events-none absolute z-10 rounded border border-line bg-base-100 px-2 py-1 font-mono text-[11px] whitespace-nowrap shadow-sm";
        this.el.style.position = this.el.style.position || "relative";
        this.el.appendChild(this._heatTip);
      }
      const time = new Date(hit.t).toLocaleTimeString([], { hour12: false });
      const unit = this._arrayUnit ? ` ${this._arrayUnit}` : "";
      const value = typeof hit.v === "number" ? formatAxisNumber(hit.v) : hit.v;
      this._heatTip.textContent = `${time}  [${hit.i}]  ${value}${unit}`;
      this._heatTip.style.display = "";
      const left = Math.min(e.offsetX + 12, this.el.clientWidth - this._heatTip.offsetWidth - 4);
      this._heatTip.style.left = `${Math.max(0, left)}px`;
      this._heatTip.style.top = `${Math.max(0, e.offsetY - 30)}px`;
    });
    zr.on("globalout", hide);
  },

  _heatCellAt(x, y) {
    for (const key of Object.keys(this._heatCache)) {
      const seriesIndex = Number(key);
      const c = this._heatCache[key];
      if (!c || c.times.length === 0 || !this._chart.containPixel({ seriesIndex }, [x, y])) continue;
      const [t, yv] = this._chart.convertFromPixel({ seriesIndex }, [x, y]);
      const i = Math.round(yv);
      // last reading at or before t
      let lo = 0;
      let hi = c.times.length - 1;
      if (t < c.times[0]) return null;
      while (lo < hi) {
        const mid = (lo + hi + 1) >> 1;
        if (c.times[mid] <= t) lo = mid;
        else hi = mid - 1;
      }
      if (t > c.ends[lo]) return null;
      const stop = lo + 1 < c.starts.length ? c.starts[lo + 1] : c.n;
      for (let j = c.starts[lo]; j < stop; j++) {
        if (c.api.value(1, j) === i) return { t: c.times[lo], i, v: c.api.value(2, j) };
      }
    }
    return null;
  },

  // Long arrays: the newest reading replaces the line.
  _applySnapshot({ data, ...info }) {
    this._arrayLatest = { ...(this._arrayLatest || {}), ...info };
    if (this._lastOption) {
      this._lastOption = {
        ...this._lastOption,
        series: [{ ...this._lastOption.series[0], data }],
        xAxis: { ...this._lastOption.xAxis, max: Math.max(info.n - 1, 1) },
      };
    }
    if (!this._chart || !this._lastOption) return;
    this._chart.setOption({
      series: [{ data }],
      xAxis: { max: Math.max(info.n - 1, 1) },
      title: this._latestTitle(),
    });
  },

  // Time slider for long-array plots: step through the stored readings.
  // At the right end it follows new readings; anywhere else it holds.
  _renderScrub() {
    const box = document.getElementById(`array-scrub-${this.el.id}`);
    const times = this._arrayTimes;
    if (!box) return;
    if (!this._arrayLatest || !times || times.length < 2) {
      box.innerHTML = "";
      box._built = false;
      return;
    }
    const last = times.length - 1;
    const idx = this._scrubIndex == null ? last : this._scrubIndex;

    if (!box._built || box._hook !== this) {
      box._hook = this;
      box.innerHTML = "";
      const btn = (icon, title) => {
        const b = document.createElement("button");
        b.type = "button";
        b.title = title;
        b.setAttribute("aria-label", title);
        b.className = "rounded border border-line p-0.5 text-muted transition-colors hover:bg-base-200 hover:text-base-content disabled:opacity-40";
        const i = document.createElement("span");
        i.className = `${icon} block size-3.5`;
        b.appendChild(i);
        return b;
      };
      const prev = btn("hero-chevron-left-micro", "Previous reading");
      const next = btn("hero-chevron-right-micro", "Next reading");
      const range = document.createElement("input");
      range.type = "range";
      range.min = "0";
      range.step = "1";
      range.className = "range range-xs min-w-0 flex-1 [--range-fill:0]";
      range.setAttribute("aria-label", "Reading shown");
      const label = document.createElement("span");
      label.className = "min-w-0 shrink-0 font-mono text-[11px] text-muted tabular-nums";
      const live = document.createElement("button");
      live.type = "button";
      live.className = "shrink-0 rounded px-1.5 py-0.5 text-[11px] transition-colors";
      box.append(prev, range, next, label, live);
      box._built = { prev, next, range, label, live };

      prev.addEventListener("click", () => this._scrubTo((this._scrubIndex ?? this._arrayTimes.length - 1) - 1));
      next.addEventListener("click", () => this._scrubTo((this._scrubIndex ?? this._arrayTimes.length - 1) + 1));
      range.addEventListener("input", () => this._scrubTo(Number(range.value), true));
      live.addEventListener("click", () => this._scrubTo(this._arrayTimes.length - 1));
    }

    const { prev, next, range, label, live } = box._built;
    range.max = String(last);
    range.value = String(idx);
    prev.disabled = idx <= 0;
    next.disabled = idx >= last;
    const d = new Date(times[idx]);
    const today = d.toDateString() === new Date().toDateString();
    label.textContent = `${idx + 1}/${times.length} · ${today ? d.toLocaleTimeString([], { hour12: false }) : d.toLocaleString([], { hour12: false })}`;
    const following = this._scrubIndex == null;
    live.textContent = following ? "latest" : "latest ›";
    live.disabled = following;
    live.title = following ? "Showing the newest reading" : "Jump to the newest reading";
    ["bg-base-300", "text-base-content", "font-semibold"].forEach((c) => live.classList.toggle(c, !following));
    live.classList.toggle("text-muted", following);
  },

  _scrubTo(i, debounce = false) {
    const times = this._arrayTimes;
    if (!times || times.length === 0) return;
    const last = times.length - 1;
    const idx = Math.max(0, Math.min(last, i));
    // the right end means "follow new readings"
    this._scrubIndex = idx === last ? null : idx;
    this._renderScrub();
    clearTimeout(this._scrubTimer);
    const t = times[idx];
    const cached = this._liveReadings && this._liveReadings.get(t);
    if (cached) {
      this._wantT = null;
      this._applySnapshot(cached);
      return;
    }
    // claim the reading now, so a reply for an earlier position is dropped
    // even while the debounce is still running
    this._wantT = t;
    const load = () => this.pushEventTo(this.el, "fetch-array-reading", { t });
    if (debounce) this._scrubTimer = setTimeout(load, 120);
    else load();
  },

  _latestTitle() {
    const a = this._arrayLatest;
    if (!a || a.t == null) return { text: "no reading yet" };
    const which = this._scrubIndex == null ? "latest" : "reading";
    const d = new Date(a.t);
    const today = d.toDateString() === new Date().toDateString();
    const time = today ? d.toLocaleTimeString([], { hour12: false }) : d.toLocaleString([], { hour12: false });
    const reduced = a.shown < a.n ? ` (min/max, ${a.shown.toLocaleString()} shown)` : "";
    return { text: `${which} ${time} · ${a.n.toLocaleString()} pts${reduced}` };
  },

  _isArrayPlot() {
    return this._arrayLen != null;
  },

  // The option to draw: the server's heatmap option, or for "lines" one line
  // per array element built from the same buffered points.
  _composeOption(option) {
    if (this._arrayLatest) {
      const css = getComputedStyle(document.documentElement);
      const unit = this._arrayLatest.unit ? ` ${escHtml(this._arrayLatest.unit)}` : "";
      return {
        ...option,
        title: {
          ...this._latestTitle(),
          right: 8,
          top: 2,
          textStyle: {
            fontSize: 11,
            fontWeight: "normal",
            color: css.getPropertyValue("--sc-muted").trim() || undefined,
            width: Math.max(this.el.clientWidth - 24, 80),
            overflow: "truncate",
          },
        },
        yAxis: { ...option.yAxis, axisLabel: { formatter: formatAxisNumber } },
        tooltip: {
          ...option.tooltip,
          formatter: (ps) => {
            const p = ps && ps[0];
            return p ? `[${p.value[0]}]  ${formatAxisNumber(p.value[1])}${unit}` : "";
          },
        },
      };
    }
    if (!this._isArrayPlot()) return option;
    const flat = this._seriesData[0] || [];
    if (this._arrayMode !== "lines") {
      const series = (option.series || []).map((s, i) => (i === 0 ? { ...s, data: flat } : s));
      return { ...option, series };
    }
    const { visualMap, ...rest } = option;
    const n = this._arrayLen || 0;
    const unit = this._arrayUnit;
    this._linesCount = n;
    return {
      ...rest,
      grid: { top: 12, bottom: 44, left: 76, right: 24 },
      xAxis: {
        ...(Array.isArray(option.xAxis) ? option.xAxis[0] : option.xAxis),
        name: "time",
        nameLocation: "middle",
        nameGap: 26,
      },
      yAxis: {
        type: "value",
        scale: true,
        splitNumber: 4,
        name: `${this._arrayName || "value"}${unit ? ` (${unit})` : ""}`,
        nameLocation: "middle",
        nameGap: 56,
        axisLabel: { formatter: formatAxisNumber },
        nameRotate: 90,
      },
      tooltip: {
        trigger: "axis",
        confine: true,
        formatter: (ps) => this._linesTooltip(ps),
      },
      series: this._splitArray(flat).map((data, i) => ({
        name: `[${i}]`,
        type: "line",
        data,
        showSymbol: false,
        symbol: "none",
        step: false,
        sampling: "lttb",
        lineStyle: { width: n > 20 ? 1 : 1.5 },
        color: arrayLineColor(i, n),
        triggerLineEvent: true,
        emphasis: { focus: "series", lineStyle: { width: 2.5 } },
        animation: false,
      })),
    };
  },

  // [[ts, index, value], ...] → one [[ts, value], ...] list per index
  _splitArray(flat) {
    const n = this._arrayLen || 0;
    const out = Array.from({ length: n }, () => []);
    for (const p of flat) {
      const list = out[p[1]];
      if (list) list.push([p[0], p[2]]);
    }
    return out;
  },

  _linesTooltip(ps) {
    if (!ps || ps.length === 0) return "";
    const esc = escHtml;
    const time = new Date(ps[0].value[0]).toLocaleTimeString([], { hour12: false });
    const unit = this._arrayUnit ? ` ${esc(this._arrayUnit)}` : "";
    const fmt = (v) => (typeof v === "number" ? formatAxisNumber(v) : esc(v));
    // pointer on a line: only that element
    const hit = this._hoverSeries != null && ps.find((p) => p.seriesIndex === this._hoverSeries);
    if (hit) {
      return (
        `<div>${time}</div>` +
        `<div style="font-size:13px;font-weight:600"><span style="color:${hit.color}">●</span> ` +
        `${esc(hit.seriesName)} ${fmt(hit.value[1])}${unit}</div>`
      );
    }
    const rows = ps
      .map((p) => `<span style="color:${p.color}">●</span> ${esc(p.seriesName)} ${fmt(p.value[1])}`)
      .join("<br>");
    const cols = ps.length > 16 ? `columns:${ps.length > 48 ? 4 : 2};column-gap:12px;` : "";
    return `<div>${time}${unit ? ` ·${unit}` : ""}</div><div style="${cols}font-size:11px;line-height:1.35">${rows}</div>`;
  },

  _redrawArray() {
    if (!this._chart || !this._lastOption) return;
    this._heatCache = {};
    this._chart.setOption(this._themed(this._composeOption(this._lastOption)), { notMerge: true });
    // keep the live window where it is until the next flush moves it
    this._dataDirty = true;
    this._flushBuffer();
  },

  _renderArrayModeButtons() {
    const el = document.getElementById(`array-mode-${this.el.id}`);
    if (!el) return;
    if (!this._isArrayPlot()) {
      el.innerHTML = "";
      return;
    }
    el.innerHTML = "";
    [
      ["heatmap", "Heatmap", "hero-squares-2x2-micro"],
      ["lines", "Lines", "hero-presentation-chart-line-micro"],
    ].forEach(([mode, label, icon]) => {
      const b = document.createElement("button");
      b.type = "button";
      const i = document.createElement("span");
      i.className = `${icon} size-3.5`;
      b.append(i, label);
      b.setAttribute("aria-pressed", String(this._arrayMode === mode));
      b.className = "inline-flex items-center gap-1 rounded px-2 py-0.5 text-xs transition-colors";
      b.title = mode === "lines" ? "One line per array element" : "Time × index, colour = value";
      this._styleRangeButton(b, this._arrayMode === mode);
      b.addEventListener("click", () => {
        if (this._arrayMode === mode) return;
        this._arrayMode = mode;
        try { localStorage.setItem(ARRAY_MODE_KEY, mode); } catch (_e) {}
        el.querySelectorAll("button").forEach((x, i) => {
          const on = i === (mode === "heatmap" ? 0 : 1);
          this._styleRangeButton(x, on);
          x.setAttribute("aria-pressed", String(on));
        });
        this._redrawArray();
      });
      el.appendChild(b);
    });
  },

  _reinitForTheme() {
    if (!this._chart || !this._lastOption) return;
    this._chart.dispose();
    this._chart = this._initChart();
    this._heatTipBound = false;
    this._heatCache = {};
    this._chart.setOption(this._themed(this._composeOption(this._lastOption)), { notMerge: true });
    this._bindHeatTooltip();
    this._dataDirty = true;
    this._flushBuffer();
  },

  // heatmap points are [t, index, value]
  _trackHeatRange(data) {
    for (const p of data) {
      const v = p[2];
      if (this._visualMapMin === null || v < this._visualMapMin) this._visualMapMin = v;
      if (this._visualMapMax === null || v > this._visualMapMax) this._visualMapMax = v;
    }
  },

  // the index axis only grows: older, longer readings stay in the buffer
  _growArrayLen(arrayLen) {
    if (this._arrayLen == null || arrayLen == null) return;
    if (arrayLen > this._arrayLen) this._arrayLen = arrayLen;
  },

  _applyInitialOption(echartsOption) {
    this._lastOption = echartsOption;
    this._heatCache = {};
    this._chart.setOption(this._themed(this._composeOption(echartsOption)), { notMerge: true });
    this._bindHeatTooltip();
    this._renderArrayModeButtons();
    this._renderScrub();
    const loadingEl = document.getElementById(this.el.dataset.loadingId);
    if (loadingEl) loadingEl.style.display = "none";
    this._renderRangeButtons();
  },

  _disposeChart() {
    if (this._chart) {
      this._chart.dispose();
      this._chart = null;
    }
  },

  _renderRangeButtons() {
    const buttonsEl = document.getElementById(`range-buttons-${this.el.id}`);
    if (!buttonsEl) return;
    if (!this._rangeButtons) {
      // e.g. a heatmap that switched to the latest-reading plot
      buttonsEl.innerHTML = "";
      return;
    }

    buttonsEl.innerHTML = "";
    this._rangeButtons.forEach((btn, index) => {
      const el = document.createElement("button");
      el.textContent = btn.label;
      el.type = "button";
      el.className = "rounded px-1.5 py-0.5 font-mono text-[11px] transition-colors";
      this._styleRangeButton(el, index === this._activeButton);
      el.addEventListener("click", () => {
        const prevBtn = this._activeButton != null ? this._rangeButtons[this._activeButton] : null;
        this._activeButton = index;
        buttonsEl
          .querySelectorAll("button")
          .forEach((b, i) => this._styleRangeButton(b, i === index));

        const now = Date.now();
        const { xMin: newXMin, xMax: newXMax } = this._computeRange(btn, now);
        const prevXMin = prevBtn ? this._computeRange(prevBtn, now).xMin : null;

        // Expanding = window is getting larger (xMin moves earlier, or going to "all")
        const isExpanding = prevXMin !== null && (newXMin === null || newXMin < prevXMin);

        if (isExpanding) {
          // No buffered point at all (e.g. a sparsely-updating parameter whose default
          // live window had zero points) still means there may be older data to backfill —
          // fall back to "now" so the request covers the whole newly-selected window.
          const earliestTs = this._earliestBufferedTs();
          const to = earliestTs !== null ? earliestTs : now;
          if (newXMin === null || newXMin < to) {
            this.pushEventTo(this.el, "fetch-chart-range", { from: newXMin, to });
          }
        } else if (!isExpanding && newXMin !== null) {
          // Shrinking: eagerly drop points that scrolled out
          Object.keys(this._seriesData).forEach((idx) => {
            this._seriesData[idx] = trimBefore(this._seriesData[idx], newXMin);
          });
        }

        if (newXMin !== null) {
          this._chart.setOption({ xAxis: this._xAxisPatch({ min: newXMin, max: newXMax }) });
        } else {
          this._chart.setOption({ xAxis: this._xAxisPatch({ min: null, max: null }) });
        }
        this._dataDirty = true;
      });
      buttonsEl.appendChild(el);
    });
  },

  _styleRangeButton(el, active) {
    ["bg-base-300", "text-base-content", "font-semibold"].forEach((c) => el.classList.toggle(c, active));
    ["text-muted", "hover:bg-base-200"].forEach((c) => el.classList.toggle(c, !active));
  },

  // Timestamp of a buffered point, regardless of series data shape:
  // plain [ts, ...] arrays (line/scatter/heatmap) or enum's {value: [ts, y], ...} objects.
  _pointTs(point) {
    return pointTs(point);
  },

  // Earliest timestamp currently buffered across all series, or null if nothing is buffered yet
  // (e.g. a live plot whose default window happens to contain zero points for a sparsely-updating
  // parameter — this must not be confused with "nothing to backfill").
  _earliestBufferedTs() {
    let earliest = null;
    Object.values(this._seriesData).forEach((d) => {
      if (!d || d.length === 0) return;
      const ts = this._pointTs(d[0]);
      if (ts != null && (earliest === null || ts < earliest)) earliest = ts;
    });
    return earliest;
  },

  _computeRange(btn, now) {
    if (btn.step === "all") return { xMin: null, xMax: null };
    const msMap = { minute: 60_000, hour: 3_600_000, day: 86_400_000 };
    const windowMs = (msMap[btn.step] || 0) * (btn.count || 1);
    return { xMin: now - windowMs, xMax: now };
  },

  _isLineSeries(idx) {
    const series = this._lastOption && this._lastOption.series;
    return !!(series && series[idx] && series[idx].type === "line");
  },

  // Line series get a point at `now` repeating their last value
  _displayData(idx, now) {
    const d = this._seriesData[idx];
    return this._isLineSeries(idx) ? withTail(d, now) : d;
  },

  _xAxisPatch(update) {
    if (this._xAxisCount <= 1) return update;
    return Array.from({ length: this._xAxisCount }, () => update);
  },

  _flushBuffer() {
    if (!this._chart || !this._rangeButtons || !this._isVisible) return;

    const now = Date.now();
    const patch = {};

    // Slide the x-axis window every tick, even with no new data — this is what
    // makes a live chart visibly advance with wall-clock time while idle.
    let xMin = null;
    if (this._activeButton != null) {
      const btn = this._rangeButtons[this._activeButton];
      const range = this._computeRange(btn, now);
      xMin = range.xMin;
      if (xMin !== null) patch.xAxis = this._xAxisPatch({ min: xMin, max: range.xMax });
    }

    // The rest (trimming + rebuilding series + heatmap extras) is the expensive
    // part — an ECharts re-diff over up to maxPoints per series — so only do it
    // when data has changed, or every TAIL_REFRESH_MS to move line tails to now.
    const tailDue =
      now - (this._tailAt || 0) >= TAIL_REFRESH_MS &&
      Object.keys(this._seriesData).some((idx) => this._isLineSeries(idx));
    if (this._dataDirty || tailDue) {
      if (xMin !== null) {
        Object.keys(this._seriesData).forEach((idx) => {
          this._seriesData[idx] = trimBefore(this._seriesData[idx], xMin);
        });
      } else {
        Object.keys(this._seriesData).forEach((idx) => {
          const d = this._seriesData[idx];
          const cap = this._isArrayPlot() ? maxArrayPoints : maxPoints;
          if (d.length > cap) this._seriesData[idx] = d.slice(d.length - cap);
        });
      }

      if (this._isArrayPlot() && this._arrayMode === "lines" && this._linesCount !== this._arrayLen) {
        // the array got longer or shorter: rebuild the line series
        this._redrawArray();
        return;
      }
      if (this._isArrayPlot() && this._arrayMode === "lines") {
        patch.series = this._splitArray(this._seriesData[0] || []).map((data) => ({ data }));
      } else {
        patch.series = Object.keys(this._seriesData).map((idx) => ({
          data: this._displayData(idx, now),
        }));
      }
      this._tailAt = now;

      if (this._isArrayPlot() && this._arrayMode !== "lines") {
        patch.yAxis = { max: Math.max(this._arrayLen, 1) - 0.5 };
        patch.animation = false;
        if (this._visualMapMin !== null && this._visualMapMax !== null) {
          const vMax = this._visualMapMax === this._visualMapMin ? this._visualMapMax + 1 : this._visualMapMax;
          patch.visualMap = { min: this._visualMapMin, max: vMax };
        }
      }

      this._dataDirty = false;
    }

    if (Object.keys(patch).length === 0) return;

    try {
      this._chart.setOption(patch);
    } catch (error) {
      console.error("ECharts flush error:", error);
    }
  },

  destroyed() {
    ThemeWatch.remove(this._onThemeChange);
    ChartFlushDriver.unregister(this);
    ChartVisibilityObserver.unobserve(this.el);
    this._resizeObserver && this._resizeObserver.disconnect();
    document.removeEventListener("toggle-rangeslider", this._toggleRangeslider);
    window.removeEventListener("myapp:close-modal", this._onCloseModal);
    this._disposeChart();
  },
};

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

function sparkTime(ms) {
  const d = new Date(ms);
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

Hooks.Sparkline = {
  mounted() {
    this.series = { value: [], target: [] };
    this.skew = 0; // node clock minus browser clock, from the newest readings
    this._visible = true;
    this.unit = this.el.dataset.unit || "";
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
    // leaves a flat line at the bottom); a flat line sits in the middle
    let lo = Infinity;
    let hi = -Infinity;
    for (const p of value.concat(target)) {
      if (p[1] < lo) lo = p[1];
      if (p[1] > hi) hi = p[1];
    }
    const flat = hi === lo;

    chart.setOption({
      xAxis: { min: start, max: now },
      yAxis: sparkRange(lo, hi),
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

Hooks.ArraySpark = {
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

window.addEventListener("phx:reveal-panel", (e) => {
  if (window.innerWidth >= 1024) return;
  const el = document.getElementById(e.detail.id);
  if (!el) return;
  const r = el.getBoundingClientRect();
  if (r.top < 0 || r.top > window.innerHeight * 0.5) el.scrollIntoView({ behavior: "smooth", block: "start" });
});

// CopyToClipboard hook for copying text with visual feedback
Hooks.CopyToClipboard = {
  mounted() {
    this.originalTooltip = this.el.dataset.tip;

    this.el.addEventListener("click", () => {
      const textToCopy = this.el.dataset.copy;

      navigator.clipboard
        .writeText(textToCopy)
        .then(() => {
          // Change tooltip to show success
          this.el.dataset.tip = "✓ Copied!";
          this.el.classList.add("tooltip-success");

          // Revert back after 2 seconds
          setTimeout(() => {
            this.el.dataset.tip = this.originalTooltip;
            this.el.classList.remove("tooltip-success");
          }, 2000);
        })
        .catch((err) => {
          console.error("Failed to copy:", err);
          // Show error feedback
          this.el.dataset.tip = "✗ Failed to copy";
          this.el.classList.add("tooltip-error");

          setTimeout(() => {
            this.el.dataset.tip = this.originalTooltip;
            this.el.classList.remove("tooltip-error");
          }, 2000);
        });
    });
  },
};

// Register hooks with LiveSocket
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: { ...Hooks, ...colocatedHooks },
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener(
    "phx:live_reload:attached",
    ({ detail: reloader }) => {
      // Enable server log streaming to client.
      // Disable with reloader.disableServerLogs()
      reloader.enableServerLogs();

      // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
      //
      //   * click with "c" key pressed to open at caller location
      //   * click with "d" key pressed to open at function component definition location
      let keyDown;
      window.addEventListener("keydown", (e) => (keyDown = e.key));
      window.addEventListener("keyup", (e) => (keyDown = null));
      window.addEventListener(
        "click",
        (e) => {
          if (keyDown === "c") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtCaller(e.target);
          } else if (keyDown === "d") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtDef(e.target);
          }
        },
        true,
      );

      window.liveReloader = reloader;
    },
  );
}
