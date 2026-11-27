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

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

const maxPoints = 20000;
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

// Envelope (min/mean/max band per bucket) on historical line plots,
// remembered per browser: on by default for plain lines, off for arrays,
// whose one band per element can bury the lines.
const ENVELOPE_KEYS = { line: "secant:envelope", array: "secant:envelope-array" };
const readEnvelopePref = (kind) => {
  try {
    const v = localStorage.getItem(ENVELOPE_KEYS[kind]);
    return v == null ? kind === "line" : v === "on";
  } catch (_e) {
    return kind === "line";
  }
};
const writeEnvelopePref = (kind, on) => {
  try {
    localStorage.setItem(ENVELOPE_KEYS[kind], on ? "on" : "off");
  } catch (_e) {}
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

// Series palette: HZB light blue first, then colours that stay apart in both
// themes (and differ in lightness, not only hue).
const CHART_PALETTE = ["#009ee0", "#8b5cf6", "#f59e0b", "#10b981", "#f43f5e", "#a3a3a8", "#ec4899", "#84cc16"];

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

// Width of a time bucket for the resolution label: 900000 → "15 min"
const formatBucket = (ms) => {
  const units = [[86_400_000, "d"], [3_600_000, "h"], [60_000, "min"], [1_000, "s"]];
  for (const [size, unit] of units) {
    if (ms >= size) return `${+(ms / size).toFixed(1)} ${unit}`;
  }
  return `${ms} ms`;
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
      const { _rangeButtons, _activeButton, _arrayLen, _arrayUnit, _arrayName, _arrayLatest, _arrayTimes, _windowFetch, _envelope, _envelopes, ...echartsOption } = option;
      // historical plots: the server thins out long recordings and
      // sends more detail for the window the chart is zoomed to
      this._windowFetch = !!_windowFetch;
      this._resolution = _windowFetch || null;
      this._overview = null;
      this._detail = null;
      this._windowReq = 0;
      clearTimeout(this._windowTimer);
      // envelope: what this plot can show, and what its overview holds
      this._envMeta = _envelope || null;
      this._overviewEnvelope = !!(_envelope && _envelope.on);
      this._overviewEnvelopes = this._envelopesBySeries(_envelopes);
      this._envGen = 0;
      this._reloadPending = false;
      this._bandCache = null;
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
      if (this._windowFetch) this._overview = { ...this._seriesData };
      // Seed min/max from initial data and bake into the option (visualMap present = heatmap)
      if (echartsOption.visualMap && this._arrayLen != null) {
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
      const { _rangeButtons, _activeButton, _arrayLen, _arrayUnit, _arrayName, _arrayLatest, _arrayTimes, _windowFetch, _envelope, _envelopes, ...echartsOption } = option;
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

    this.handleEvent(`window-chart-data-${this.el.id}`, (reply) => this._applyWindow(reply));
    this.handleEvent(`overview-chart-data-${this.el.id}`, (reply) => this._applyOverview(reply));
    this.handleEvent(`overview-chart-error-${this.el.id}`, (reply) => this._overviewFailed(reply));

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
      // all time axes of a multi-grid (struct) plot move together
      const axes = this._xAxisCount > 1 ? [...Array(this._xAxisCount).keys()] : 0;
      const zooms = (currentOption.dataZoom || [])
        .filter(Boolean)
        .map((dz) => ({ type: dz.type, xAxisIndex: axes, filterMode: dz.filterMode }));
      const hasSlider = zooms.some((dz) => dz.type === "slider");
      const filterMode = zooms.length ? zooms[0].filterMode : undefined;
      const nextZooms = hasSlider
        ? zooms.filter((dz) => dz.type !== "slider")
        : [...zooms, { type: "slider", xAxisIndex: axes, bottom: 8, filterMode }];
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
    const chart = echarts.init(this.el, isDarkTheme() ? "dark" : null, { renderer: "canvas" });
    // zooming and panning (wheel, drag, box zoom, slider) and the reset tool
    chart.on("datazoom", () => this._onWindowMoved());
    chart.on("restore", () => this._onWindowMoved());
    return chart;
  },

  // --- Detail on zoom (historical plots) -----------------------------------
  // The first load covers the whole recording, thinned out by the server
  // (`_overview`). After a zoom or pan the visible window is requested again;
  // the reply (`_detail`) replaces the overview inside that window, so the
  // time axis keeps its full extent and zooming out works without waiting.

  // [min, max] of the time axis as currently shown
  _visibleWindow() {
    const axis = this._chart?.getModel()?.getComponent("xAxis", 0)?.axis;
    const extent = axis?.scale.getExtent();
    return extent && extent.every(Number.isFinite) ? extent : null;
  },

  // [first, last] timestamp of the overview
  _overviewExtent() {
    let lo = null;
    let hi = null;
    Object.values(this._overview || {}).forEach((d) => {
      if (!d.length) return;
      const a = this._pointTs(d[0]);
      const b = this._pointTs(d[d.length - 1]);
      if (lo === null || a < lo) lo = a;
      if (hi === null || b > hi) hi = b;
    });
    return lo === null ? null : [lo, hi];
  },

  _onWindowMoved() {
    // the setpoint's pins follow the window at once, not with the detail
    // (after the event: ECharts takes no setOption while it dispatches)
    queueMicrotask(() => {
      const series = this._windowFetch && this._targetSeriesPatch();
      if (series) this._chart.setOption({ series });
    });
    this._scheduleWindowFetch();
  },

  _scheduleWindowFetch() {
    if (!this._windowFetch) return;
    clearTimeout(this._windowTimer);
    this._windowTimer = setTimeout(() => this._fetchWindow(), 250);
  },

  _fetchWindow() {
    if (!this._chart || !this._windowFetch) return;
    // an overview in the other mode is on its way; the window follows it
    if (this._reloadPending) return;
    const visible = this._visibleWindow();
    const full = this._overviewExtent();
    if (!visible || !full) return;
    const [from, to] = visible;

    // zoomed all the way out: the overview is all there is to show
    if (from <= full[0] && to >= full[1]) {
      this._windowReq++; // a reply still on its way is outdated
      this._detail = null;
      this._bandCache = null;
      this._drawWindowData();
      return;
    }
    // every reading of this window is already loaded
    const d = this._detail;
    if (d && !d.aggregated && from >= d.from && to <= d.to) return;

    // some margin on both sides, so that short pans stay inside the detail
    const pad = (to - from) / 2;
    this.pushEventTo(this.el, "fetch-chart-window", {
      from: Math.floor(Math.max(from - pad, full[0])),
      to: Math.ceil(Math.min(to + pad, full[1])),
      req: ++this._windowReq,
      envelope: this._envFlag(),
      gen: this._envGen || 0,
    });
  },

  _applyWindow({ req, gen, from, to, aggregated, bucket_ms, envelope_bucket_ms, seriesUpdates, envelopes, arrayLen }) {
    // only the answer to the latest request (the chart may have moved on),
    // in the envelope mode the chart is in now
    if (!this._windowFetch || req !== this._windowReq) return;
    if (gen != null && gen !== (this._envGen || 0)) return;
    const series = {};
    (seriesUpdates || []).forEach(({ seriesIndex, data }) => {
      series[seriesIndex] = data;
    });
    this._bandCache = null;
    this._detail = {
      from,
      to,
      aggregated,
      bucket_ms,
      envelope_bucket_ms,
      series,
      envelopes: this._envelopesBySeries(envelopes),
    };
    // element rows can show a wider array than the thinned readings did:
    // merge the window first, then rebuild with the new element's line
    const grew = this._growsArray(arrayLen);
    this._drawWindowData();
    if (grew) this._recompose();
  },

  // A reloaded overview in the other envelope mode (after the toggle, a
  // Heatmap/Lines switch, or a first load whose mode differs from the
  // browser's preference) replaces the old one; then the zoomed window.
  _applyOverview({ gen, envelope, seriesUpdates, envelopes, arrayLen, aggregated, bucket_ms, envelope_bucket_ms }) {
    if (!this._windowFetch || gen !== this._envGen) return;
    this._reloadPending = false;
    this._overviewEnvelope = !!envelope;
    const overview = { ...(this._overview || {}) };
    (seriesUpdates || []).forEach(({ seriesIndex, data }) => {
      overview[seriesIndex] = data;
    });
    this._overview = overview;
    this._bandCache = null;
    this._overviewEnvelopes = this._envelopesBySeries(envelopes);
    this._seriesData = { ...overview };
    if (this._lastOption && Array.isArray(this._lastOption.series)) {
      this._lastOption = {
        ...this._lastOption,
        series: this._lastOption.series.map((s, i) => (overview[i] ? { ...s, data: overview[i] } : s)),
      };
    }
    if (this._arrayLen != null) {
      this._visualMapMin = null;
      this._visualMapMax = null;
      this._trackHeatRange(this._seriesData[0] || []);
    }
    this._growsArray(arrayLen);
    this._resolution = { aggregated, bucket_ms, envelope_bucket_ms };
    this._detail = null;
    this._recompose();
    this._fetchWindow();
  },

  // the reload failed: stay in the mode the overview holds
  _overviewFailed({ gen }) {
    if (gen !== this._envGen) return;
    this._reloadPending = false;
    if (this._envMeta) writeEnvelopePref(this._envMeta.kind, this._overviewEnvelope);
    // the loaded overview holds bucket means: only Lines mode draws them
    if (this._envMeta && this._envMeta.kind === "array" && this._overviewEnvelope && this._arrayMode !== "lines") {
      this._arrayMode = "lines";
      try { localStorage.setItem(ARRAY_MODE_KEY, "lines"); } catch (_e) {}
      this._recompose();
    }
    this._renderEnvelopeToggle();
    this._fetchWindow();
  },

  // payloads by series index: {bucket_ms, from, until, rows}
  _envelopesBySeries(list) {
    const out = {};
    (list || []).forEach((e) => {
      if (e && e.seriesIndex != null) out[e.seriesIndex] = e;
    });
    return out;
  },

  _growsArray(arrayLen) {
    if (this._arrayLen == null || arrayLen == null || arrayLen <= this._arrayLen) return false;
    this._arrayLen = arrayLen;
    return this._arrayMode === "lines";
  },

  // overview outside the detail window, detail inside
  _drawWindowData() {
    if (!this._chart || !this._overview) return;
    const d = this._detail;
    Object.keys(this._overview).forEach((idx) => {
      const overview = this._overview[idx];
      const detail = d && d.series[idx];
      this._seriesData[idx] = detail
        ? [
            ...overview.filter((p) => this._pointTs(p) < d.from),
            ...detail,
            ...overview.filter((p) => this._pointTs(p) > d.to),
          ]
        : overview;
    });
    // in lines mode an array buffer is drawn as one series per element
    this._chart.setOption({ series: this._seriesPatch() });
    this._renderResolution();
  },

  // The data of every drawn series, plus whether a line is sampled: not
  // while it shows bucket means (each one counts), as today otherwise.
  _seriesPatch() {
    const data = this._chartSeriesData();
    if (!this._envActive()) return data.map((d) => ({ data: d }));
    const map = this._seriesMap || [];
    return data.map((d, j) => {
      const m = map[j];
      if (!m || m.band || !this._bandParent(m)) return { data: d };
      return { data: d, sampling: this._hasBand(m.src, m.elem) ? "none" : "lttb" };
    });
  },

  // --- Envelope (min/mean/max per bucket) ---------------------------------
  // The server puts each bucket's mean into the line and sends the band
  // rows apart (per series: [t, min, mean, max], arrays [t, i, min, mean,
  // max]). Overview rows show outside the zoomed window, its rows inside.

  // a drawn line that can carry a band: an array element, or a line the
  // server named (a Drivable's `value`, not its `target`)
  _bandParent(m) {
    if (!m || m.band) return false;
    return this._isArrayPlot() ? m.elem != null : (this._envMeta.series || []).includes(m.src);
  },

  // the envelope the user wants for this plot right now
  _envFlag() {
    const m = this._envMeta;
    if (!m || !this._windowFetch) return false;
    if (m.kind === "array" && this._arrayMode !== "lines") return false;
    return readEnvelopePref(m.kind);
  },

  // bands are drawn: the overview the chart shows holds an envelope
  _envActive() {
    return !!this._envMeta && this._overviewEnvelope && (this._envMeta.kind === "line" || this._arrayMode === "lines");
  },

  // band rows of a series, overview outside the zoomed window and detail
  // inside, with a break (null) wherever one segment ends and the next begins
  _bandRows(src) {
    const ov = (this._overviewEnvelopes[src] || {}).rows || [];
    const d = this._detail;
    if (!d) return ov;
    const inner = ((d.envelopes || {})[src] || {}).rows || [];
    const segments = [ov.filter((r) => r[0] < d.from), inner, ov.filter((r) => r[0] > d.to)].filter((g) => g.length);
    const out = [];
    segments.forEach((g, k) => {
      if (k > 0) out.push(null);
      out.push(...g);
    });
    return out;
  },

  // rows of one band: a line's own, or one array element's (cached until
  // the overview or the zoomed window changes)
  _bandRowsOf(src, elem) {
    this._bandCache = this._bandCache || {};
    const key = `${src}:${elem}`;
    if (!this._bandCache[key]) this._bandCache[key] = this._splitBandRows(src, elem);
    return this._bandCache[key];
  },

  _splitBandRows(src, elem) {
    const rows = this._bandRows(src);
    if (elem == null) return rows.map((r) => (r ? { t: r[0], min: r[1], mean: r[2], max: r[3] } : null));
    return rows
      .filter((r) => r === null || r[1] === elem)
      .map((r) => (r ? { t: r[0], min: r[2], mean: r[3], max: r[4] } : null));
  },

  _hasBand(src, elem) {
    return this._bandRowsOf(src, elem).some((r) => r);
  },

  // helper series data: the lower edge, and the range stacked on it
  _bandData(src, elem, which) {
    const rows = this._bandRowsOf(src, elem);
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

  // The band row at time t of a line (or array element), for the tooltip.
  _bandRowAt(src, elem, t) {
    return this._bandRowsOf(src, elem).find((r) => r && r.t === t) || null;
  },

  // Adds the band helpers to a composed option: per envelope line a lower
  // series and a range series stacked on it, after all other series so the
  // server's series indexes stay put. Same name as the line, so its legend
  // entry hides the band too.
  _withBands(option) {
    if (!this._envActive()) return option;
    const base = option.series || [];
    const map = this._seriesMap || base.map((_s, i) => ({ src: i, elem: null }));
    const n = this._arrayLen || 0;
    const parents = [];
    map.forEach((m, j) => {
      if (!this._bandParent(m)) return;
      const color = this._isArrayPlot() ? arrayLineColor(m.elem, n) : CHART_PALETTE[j % CHART_PALETTE.length];
      parents.push({ ...m, parent: base[j], color });
    });
    const helpers = [];
    const helperMap = [];
    parents.forEach(({ src, elem, parent, color }) => {
      const key = `env-${src}-${elem == null ? "x" : elem}`;
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
      helpers.push({ ...common, id: `${key}-lower`, data: this._bandData(src, elem, "lower") });
      helpers.push({
        ...common,
        id: `${key}-range`,
        areaStyle: { color, opacity: isDarkTheme() ? 0.22 : 0.16 },
        data: this._bandData(src, elem, "range"),
      });
      helperMap.push({ src, elem, band: "lower" }, { src, elem, band: "range" });
    });
    this._seriesMap = [...map, ...helperMap];
    const series = base.map((s, j) => {
      const m = map[j];
      // a line of bucket means: every mean counts, and no markers on them
      return m && !m.band && helpers.length && this._hasBand(m.src, m.elem)
        ? { ...s, sampling: "none", showSymbol: false }
        : s;
    });
    const tooltip = this._isArrayPlot()
      ? option.tooltip
      : { ...(option.tooltip || {}), trigger: "axis", formatter: (ps) => this._envelopeTooltip(ps) };
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
      const band = m ? this._bandRowAt(m.src, m.elem, p.value[0]) : null;
      seen.add(p.seriesName);
      const text = band ? `${fmt(band.mean)} <span style="opacity:.7">(${fmt(band.min)} … ${fmt(band.max)})</span>` : fmt(v);
      rows.push(`<span style="color:${p.color}">●</span> ${esc(p.seriesName)} ${text}`);
    });
    return head + rows.join("<br>");
  },

  // Rebuilds the chart from scratch (bands appear or go, the array grew),
  // keeping its zoom and the legend's hidden series.
  _recompose() {
    if (!this._chart || !this._lastOption) return;
    this._heatCache = {};
    const shown = this._windowFetch ? this._visibleWindow() : null;
    const full = this._overviewExtent();
    const current = this._chart.getOption();
    const legend = (current.legend || [])[0];
    const selected = legend && legend.selected;
    // an open time range slider stays open
    const zooms = (current.dataZoom || []).filter(Boolean);
    const slider = zooms.some((dz) => dz.type === "slider");
    let option = this._themed(this._composeOption(this._lastOption));
    if (selected && option.legend && !Array.isArray(option.legend)) {
      option = { ...option, legend: { ...option.legend, selected } };
    }
    this._chart.setOption(option, { notMerge: true });
    if (slider) {
      const update = {
        dataZoom: zooms.map((dz) => ({ type: dz.type, xAxisIndex: dz.xAxisIndex, filterMode: dz.filterMode, ...(dz.type === "slider" ? { bottom: 8 } : {}) })),
      };
      if (this._xAxisCount === 1) update.grid = { bottom: 80 };
      this._chart.setOption(update, { replaceMerge: ["dataZoom"] });
    }
    if (shown && full && (shown[0] > full[0] || shown[1] < full[1])) {
      this._chart.dispatchAction({ type: "dataZoom", startValue: shown[0], endValue: shown[1] });
    }
    this._chart.setOption({ series: this._seriesPatch() });
    this._renderArrayModeButtons();
    this._renderEnvelopeToggle();
    this._renderResolution();
  },

  // The envelope switch, next to Heatmap/Lines: for historical line plots,
  // and for arrays only while they are drawn as lines.
  _renderEnvelopeToggle() {
    const el = document.getElementById(`envelope-toggle-${this.el.id}`);
    if (!el) return;
    const m = this._envMeta;
    if (!m || !this._windowFetch || (m.kind === "array" && this._arrayMode !== "lines")) {
      el.innerHTML = "";
      return;
    }
    const on = readEnvelopePref(m.kind);
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
        writeEnvelopePref(m.kind, !readEnvelopePref(m.kind));
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

  // The wanted envelope mode changed: back to the loaded overview's mode at
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
      this._recompose();
      this._fetchWindow();
    } else {
      this._reloadPending = true;
      this.pushEventTo(this.el, "fetch-chart-overview", { envelope: want, gen: this._envGen });
    }
    this._renderEnvelopeToggle();
  },

  // "thinned · 15 min intervals" while readings are thinned out, "every reading" once
  // the zoomed window shows all of them
  _renderResolution() {
    const el = document.getElementById(`resolution-${this.el.id}`);
    if (!el) return;
    const r = this._detail || this._resolution;
    if (!this._windowFetch || !r) {
      el.textContent = "";
      el.removeAttribute("title");
    } else if (r.envelope_bucket_ms && this._envActive()) {
      el.textContent = `min/mean/max · ${formatBucket(r.envelope_bucket_ms)} intervals`;
      el.title = "Each interval shows the band from its lowest to its highest value, and the line runs through its mean. Zoom in to see the readings.";
    } else if (r.aggregated) {
      el.textContent = `thinned · ${formatBucket(r.bucket_ms)} intervals`;
      el.title = "Long recordings are thinned out: each interval shows its first and last reading, and the readings with the lowest and highest values and with each state. Zoom in to see every reading.";
    } else {
      el.textContent = "every reading";
      el.title = "Every recorded reading in this time range is shown.";
    }
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
    this._targetIdx = new Set();
    const series = (option.series || []).map((s, i) => {
      if (s && s._enumBand) return this._enumBand(s, live);
      if (s && s._arrayHeat) return this._arrayHeat(s, live, i);
      if (s && s._target) {
        this._targetIdx.add(String(s._src != null ? s._src : i));
        const color = muted ? { lineStyle: { ...(s.lineStyle || {}), color: muted }, itemStyle: { ...(s.itemStyle || {}), color: muted } } : {};
        return { ...s, ...color, data: this._heldTarget(s.data || [], option.series) };
      }
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
      // no tweening: on every update the points would slide into place
      animation: false,
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
        // value and target of a drivable's array share each row: value in
        // the upper half, target in the lower one
        const half = series._heatHalf;
        const cellH = half ? rowH / 2 : rowH;
        const cellTop = half === "lower" ? 0 : -rowH / 2;
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
            ctx.fillRect(x0, y + cellTop, w, cellH + 0.5);
          }
        }

        const label = half ? (series._targetArray ? "target" : "value") : null;
        this._heatCache[seriesIndex] = { times, ends, starts, n, api, half, label };
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
      this._heatTip.textContent = `${time}  [${hit.i}]  ${value}${unit}${hit.label ? `  ${hit.label}` : ""}`;
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
      // indices grow upwards: above the row's middle is the upper half
      if (c.half === "upper" && yv < i) continue;
      if (c.half === "lower" && yv > i) continue;
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
        if (c.api.value(1, j) === i) return { t: c.times[lo], i, v: c.api.value(2, j), label: c.label };
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

  // The option to draw, with envelope bands where they are on.
  _composeOption(option) {
    return this._withBands(this._composeBase(option));
  },

  // The option to draw: the server's heatmap option, or for "lines" one line
  // per array element built from the same buffered points.
  _composeBase(option) {
    // which buffer each drawn series shows; null = one series per buffer
    this._seriesMap = null;
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
    if (!this._isArrayPlot()) return this._hasArrayFields() ? this._composeStruct(option) : option;
    const flat = this._seriesData[0] || [];
    if (this._arrayMode !== "lines") {
      const series = (option.series || []).map((s, i) => (i === 0 ? { ...s, data: flat } : s));
      return { ...option, series };
    }
    const { visualMap, ...rest } = option;
    const n = this._arrayLen || 0;
    const unit = this._arrayUnit;
    this._linesCount = n;
    this._seriesMap = Array.from({ length: n }, (_, k) => ({ src: 0, elem: k }));
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

  // A struct plot's array fields, as heatmap rows or, in "lines" mode, one
  // line per element on the same row (a drivable's target dashed). The
  // buffered data stays one series per field; `_seriesMap` says which
  // buffer and element each drawn series shows.
  _composeStruct(option) {
    const lines = this._arrayMode === "lines";
    const series = [];
    const map = [];
    const lineAxes = new Set();
    (option.series || []).forEach((s, i) => {
      if (lines && s && s._arrayHeat) {
        const n = s._arrayLen || 0;
        lineAxes.add(s.yAxisIndex || 0);
        for (let k = 0; k < n; k++) {
          series.push({
            name: `${s.name}[${k}]`,
            type: "line",
            xAxisIndex: s.xAxisIndex,
            yAxisIndex: s.yAxisIndex,
            showSymbol: false,
            symbol: "none",
            sampling: "lttb",
            color: arrayLineColor(k, n),
            lineStyle: { width: n > 20 ? 1 : 1.5, type: s._targetArray ? [6, 4] : "solid" },
            animation: false,
          });
          map.push({ src: i, elem: k });
        }
      } else {
        series.push({ ...s, _src: i });
        map.push({ src: i, elem: null });
      }
    });
    this._seriesMap = map;
    const data = this._chartSeriesData();
    const filled = series.map((s, j) => ({ ...s, data: data[j] }));
    if (!lines) return { ...option, series: filled };
    const { visualMap, ...rest } = option;
    // titles that describe the heatmap halves have a lines version
    const title = Array.isArray(option.title)
      ? option.title.map((t) => (t && t._linesText ? { ...t, text: t._linesText } : t))
      : option.title;
    const yAxis = (option.yAxis || []).map((ax, j) =>
      lineAxes.has(j)
        ? {
            gridIndex: ax.gridIndex,
            type: "value",
            scale: true,
            splitNumber: 3,
            axisLabel: { formatter: formatAxisNumber, hideOverlap: true },
          }
        : ax,
    );
    return { ...rest, title, yAxis, series: filled };
  },

  _hasArrayFields() {
    return ((this._lastOption && this._lastOption.series) || []).some((s) => s && s._arrayHeat);
  },

  // The data of each drawn series, from the buffers: as buffered, or one
  // element of an array buffer (lines mode).
  _chartSeriesData() {
    const map = this._seriesMap;
    if (!map) return Object.keys(this._seriesData).map((idx) => this._drawnData(idx));
    const split = {};
    return map.map(({ src, elem, band }) => {
      if (band) return this._bandData(src, elem, band);
      if (elem == null) return this._drawnData(src);
      if (!split[src]) split[src] = this._splitArray(this._seriesData[src] || [], this._elementCount(src));
      return split[src][elem] || [];
    });
  },

  _elementCount(src) {
    const s = this._lastOption && this._lastOption.series && this._lastOption.series[src];
    return s && s._arrayLen != null ? s._arrayLen : this._arrayLen || 0;
  },

  // [[ts, index, value], ...] → one [[ts, value], ...] list per index
  _splitArray(flat, count) {
    const n = count != null ? count : this._arrayLen || 0;
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
    // a bucket of an envelope: its mean, with its min and max
    const val = (p) => {
      const m = this._envActive() && (this._seriesMap || [])[p.seriesIndex];
      const b = m ? this._bandRowAt(m.src, m.elem, p.value[0]) : null;
      return b ? `${fmt(b.mean)} (${fmt(b.min)} … ${fmt(b.max)})` : fmt(p.value[1]);
    };
    // pointer on a line: only that element
    const hit = this._hoverSeries != null && ps.find((p) => p.seriesIndex === this._hoverSeries);
    if (hit) {
      return (
        `<div>${time}</div>` +
        `<div style="font-size:13px;font-weight:600"><span style="color:${hit.color}">●</span> ` +
        `${esc(hit.seriesName)} ${val(hit)}${unit}</div>`
      );
    }
    const seen = new Set();
    const rows = ps
      .filter((p) => !seen.has(p.seriesName) && seen.add(p.seriesName))
      .map((p) => `<span style="color:${p.color}">●</span> ${esc(p.seriesName)} ${val(p)}`)
      .join("<br>");
    const cols = ps.length > 16 ? `columns:${ps.length > 48 ? 4 : 2};column-gap:12px;` : "";
    return `<div>${time}${unit ? ` ·${unit}` : ""}</div><div style="${cols}font-size:11px;line-height:1.35">${rows}</div>`;
  },

  _redrawArray() {
    if (!this._chart || !this._lastOption) return;
    this._heatCache = {};
    // rebuilding the chart resets its zoom: keep the window it shows
    const shown = this._windowFetch ? this._visibleWindow() : null;
    const full = this._overviewExtent();
    this._chart.setOption(this._themed(this._composeOption(this._lastOption)), { notMerge: true });
    if (shown && full && (shown[0] > full[0] || shown[1] < full[1])) {
      this._chart.dispatchAction({ type: "dataZoom", startValue: shown[0], endValue: shown[1] });
    }
    // keep the live window where it is until the next flush moves it
    this._dataDirty = true;
    this._flushBuffer();
  },

  _renderArrayModeButtons() {
    const el = document.getElementById(`array-mode-${this.el.id}`);
    if (!el) return;
    if (!this._isArrayPlot() && !this._hasArrayFields()) {
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
        // the envelope shows only in Lines mode
        if (this._envMeta && (this._reloadPending || this._envFlag() !== this._overviewEnvelope)) {
          this._onEnvFlagChange();
        } else {
          this._renderEnvelopeToggle();
        }
      });
      el.appendChild(b);
    });
  },

  _reinitForTheme() {
    if (!this._chart || !this._lastOption) return;
    // the rebuilt chart is zoomed out again and shows the overview: reset
    // before composing, since array lines are built from the buffers
    if (this._windowFetch && this._overview) {
      this._windowReq = (this._windowReq || 0) + 1;
      this._detail = null;
      this._bandCache = null;
      this._seriesData = { ...this._overview };
    }
    this._chart.dispose();
    this._chart = this._initChart();
    this._heatTipBound = false;
    this._heatCache = {};
    this._chart.setOption(this._themed(this._composeOption(this._lastOption)), { notMerge: true });
    this._bindHeatTooltip();
    // the rebuilt chart is zoomed out again and shows the overview
    this._windowReq = (this._windowReq || 0) + 1;
    this._detail = null;
    this._renderResolution();
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
    this._renderResolution();
    this._renderEnvelopeToggle();
    // the browser's preference differs from the server's default
    if (this._envMeta && this._envFlag() !== this._overviewEnvelope) this._onEnvFlagChange();
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
          Object.keys(this._seriesData).forEach((idx) => this._trimBefore(idx, newXMin));
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
    if (!point) return null;
    return Array.isArray(point) ? point[0] : (point.value ? point.value[0] : null);
  },

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

  _pointValue(point) {
    return Array.isArray(point) ? point[1] : point.value[1];
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

  // drop readings left of the window; a setpoint keeps the one still in force
  _trimBefore(idx, xMin) {
    const d = this._seriesData[idx];
    if (d.length === 0 || this._pointTs(d[0]) >= xMin) return;
    let cutoff = d.findIndex((p) => this._pointTs(p) >= xMin);
    if (cutoff === -1) cutoff = d.length;
    if (this._targetIdx && this._targetIdx.has(String(idx))) cutoff -= 1;
    if (cutoff > 0) this._seriesData[idx] = d.slice(cutoff);
  },

  _drawnData(idx) {
    const d = this._seriesData[idx];
    return this._targetIdx && this._targetIdx.has(String(idx)) ? this._heldTarget(d) : d;
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
    // when data has actually changed since the last flush.
    if (this._dataDirty) {
      if (xMin !== null) {
        Object.keys(this._seriesData).forEach((idx) => this._trimBefore(idx, xMin));
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
      patch.series = this._chartSeriesData().map((data) => ({ data }));

      if (this._isArrayPlot() && this._arrayMode !== "lines") {
        patch.yAxis = { max: Math.max(this._arrayLen, 1) - 0.5 };
        patch.animation = false;
        if (this._visualMapMin !== null && this._visualMapMax !== null) {
          const vMax = this._visualMapMax === this._visualMapMin ? this._visualMapMax + 1 : this._visualMapMax;
          patch.visualMap = { min: this._visualMapMin, max: vMax };
        }
      }

      this._dataDirty = false;
    } else if (this._targetIdx && this._targetIdx.size > 0) {
      // nothing new, but the held setpoint still has to reach "now"
      patch.series = this._targetSeriesPatch();
    }

    if (Object.keys(patch).length === 0) return;

    try {
      this._chart.setOption(patch);
    } catch (error) {
      console.error("ECharts flush error:", error);
    }
  },

  destroyed() {
    clearTimeout(this._windowTimer);
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

Hooks.Sparkline = {
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
