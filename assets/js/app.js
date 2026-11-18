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
    this._arrayLen = null; // non-null for heatmap plots; drives yAxis.max updates
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
      const { _rangeButtons, _activeButton, _arrayLen, ...echartsOption } = option;
      this._rangeButtons = _rangeButtons || null;
      this._activeButton = _activeButton != null ? _activeButton : null;
      this._arrayLen = _arrayLen != null ? _arrayLen : null;

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

    this.handleEvent("chart-update", ({ option }) => {
      const { _rangeButtons, _activeButton, ...echartsOption } = option;
      this._lastOption = echartsOption;
      this._chart && this._chart.setOption(this._themed(echartsOption), { notMerge: true });
    });

    this.handleEvent(`prepend-chart-data-${this.el.id}`, ({ seriesUpdates }) => {
      (seriesUpdates || []).forEach(({ seriesIndex, data }) => {
        if (!this._seriesData[seriesIndex]) this._seriesData[seriesIndex] = [];
        this._seriesData[seriesIndex] = [...data, ...this._seriesData[seriesIndex]];
      });
      this._dataDirty = true;
    });

    this.handleEvent(`extend-chart-${this.el.id}`, ({ seriesUpdates, arrayLen }) => {
      (seriesUpdates || []).forEach(({ seriesIndex, data }) => {
        if (!this._seriesData[seriesIndex]) this._seriesData[seriesIndex] = [];
        this._seriesData[seriesIndex].push(...data);
        // Update running min/max for heatmap series (values at index 2)
        if (this._arrayLen != null && seriesIndex === 0) {
          for (const p of data) {
            const v = p[2];
            if (this._visualMapMin === null || v < this._visualMapMin) this._visualMapMin = v;
            if (this._visualMapMax === null || v > this._visualMapMax) this._visualMapMax = v;
          }
        }
      });
      if (arrayLen != null && arrayLen !== this._arrayLen) {
        this._arrayLen = arrayLen;
      }
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
    const yAxis = mapAxes(option.yAxis, tint);
    const inactive = isDarkTheme() ? "#6b6b70" : "#9a9aa0";
    const live = Array.isArray(option._rangeButtons);
    const series = (option.series || []).map((s) => (s && s._enumBand ? this._enumBand(s, live) : s));
    const legend = mapAxes(
      option.legend,
      (l) => l && { inactiveColor: inactive, ...l, textStyle: { color: muted, ...(l.textStyle || {}) } },
    );
    return {
      color: CHART_PALETTE,
      ...option,
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

  _reinitForTheme() {
    if (!this._chart || !this._lastOption) return;
    this._chart.dispose();
    this._chart = this._initChart();
    this._chart.setOption(this._themed(this._lastOption), { notMerge: true });
    this._dataDirty = true;
    this._flushBuffer();
  },

  _applyInitialOption(echartsOption) {
    this._lastOption = echartsOption;
    this._chart.setOption(this._themed(echartsOption), { notMerge: true });
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
    if (!buttonsEl || !this._rangeButtons) return;

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
            const d = this._seriesData[idx];
            if (d.length > 0 && this._pointTs(d[0]) < newXMin) {
              const cutoff = d.findIndex(p => this._pointTs(p) >= newXMin);
              this._seriesData[idx] = cutoff === -1 ? [] : d.slice(cutoff);
            }
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
    if (!point) return null;
    return Array.isArray(point) ? point[0] : (point.value ? point.value[0] : null);
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
        Object.keys(this._seriesData).forEach((idx) => {
          const d = this._seriesData[idx];
          if (d.length > 0 && this._pointTs(d[0]) < xMin) {
            const cutoff = d.findIndex(p => this._pointTs(p) >= xMin);
            this._seriesData[idx] = cutoff === -1 ? [] : d.slice(cutoff);
          }
        });
      } else {
        Object.keys(this._seriesData).forEach((idx) => {
          const d = this._seriesData[idx];
          if (d.length > maxPoints) this._seriesData[idx] = d.slice(d.length - maxPoints);
        });
      }

      patch.series = Object.keys(this._seriesData).map((idx) => ({
        data: this._seriesData[idx],
      }));

      if (this._arrayLen != null) {
        patch.yAxis = { max: this._arrayLen - 1 };
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
// The server sends the history once and then only new readings; the lines are
// drawn here so the server keeps no per-card buffer and re-sends no SVG.
// ---------------------------------------------------------------------------

const SPARK_WINDOW_MS = 10 * 60 * 1000;
const SPARK_MAX_POINTS = 2000;
const SPARK_W = 200;
const SPARK_H = 32;

// one timer for all sparklines: keeps the time axis moving between batches
const SparkDriver = {
  _hooks: new Set(),
  _timer: null,
  add(hook) {
    this._hooks.add(hook);
    if (!this._timer) this._timer = setInterval(() => this._hooks.forEach((h) => h._visible && h.draw()), 3000);
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

Hooks.Sparkline = {
  mounted() {
    this.series = { value: [], target: [] };
    this.skew = 0; // node clock minus browser clock, from the newest readings
    this._visible = true;
    const q = (role) => this.el.querySelector(`[data-role=${role}]`);
    this.lines = { value: q("value"), target: q("target"), empty: q("empty") };

    this.handleEvent(`spark-init-${this.el.id}`, (history) => {
      ["value", "target"].forEach((s) => {
        const hist = history[s] || [];
        const lastT = hist.length ? hist[hist.length - 1][0] : -Infinity;
        // keep live readings that arrived while the history was loading
        this.series[s] = hist.concat(this.series[s].filter((p) => p[0] > lastT));
      });
      this.draw();
    });

    this.handleEvent(`spark-add-${this.el.id}`, ({ s, p }) => {
      if (!this.series[s] || p.length === 0) return;
      this.series[s].push(...p);
      if (this.series[s].length > SPARK_MAX_POINTS) this.series[s] = this.series[s].slice(-SPARK_MAX_POINTS);
      this.skew = p[p.length - 1][0] - Date.now();
      if (this._visible) this.draw();
    });

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

    if (value.length === 0) {
      this.lines.empty.style.display = "";
      this.lines.value.setAttribute("points", "");
      this.lines.target.setAttribute("points", "");
      return;
    }
    this.lines.empty.style.display = "none";

    // x spans 10 minutes, or less while there is less data (fresh node); the
    // value line sets the start, older target readings are clamped to it
    const start = Math.max(cutoff, Math.min(value[0][0], now - 60_000));
    const span = Math.max(now - start, 1);

    let lo = Infinity;
    let hi = -Infinity;
    for (const p of value.concat(target)) {
      if (p[1] < lo) lo = p[1];
      if (p[1] > hi) hi = p[1];
    }
    const range = hi - lo;
    const x = (t) => Math.max(0, ((t - start) / span) * SPARK_W).toFixed(1);
    const y = (v) => (range === 0 ? SPARK_H / 2 : SPARK_H - 3 - ((v - lo) / range) * (SPARK_H - 6)).toFixed(1);

    // step line: each reading holds until the next one, then until now
    const steps = (points) => {
      if (points.length === 0) return "";
      const out = [];
      points.forEach((p, i) => {
        if (i > 0) out.push(`${x(p[0])},${y(points[i - 1][1])}`);
        out.push(`${x(p[0])},${y(p[1])}`);
      });
      out.push(`${SPARK_W},${y(points[points.length - 1][1])}`);
      return out.join(" ");
    };

    this.lines.value.setAttribute("points", steps(value));
    this.lines.value.style.opacity = range === 0 ? "0.4" : "";
    this.lines.target.setAttribute("points", steps(target));
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
