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
const INSPECTOR_RESERVED = 544; // 34rem
const inspectorMax = () => Math.max(INSPECTOR_MIN, window.innerWidth - INSPECTOR_RESERVED);
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
      const hasSlider = (currentOption.dataZoom || []).some(
        (dz) => dz.type === "slider",
      );
      this._chart.setOption(
        { dataZoom: hasSlider ? [] : [{ type: "slider", xAxisIndex: 0 }] },
        { replaceMerge: ["dataZoom"] },
      );
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
    const xAxis = Array.isArray(option.xAxis) ? option.xAxis.map(fixAxis) : fixAxis(option.xAxis);
    return {
      color: CHART_PALETTE,
      ...option,
      ...(xAxis ? { xAxis } : {}),
      backgroundColor: "transparent",
      textStyle: { fontFamily: "JetBrains Mono, ui-monospace, monospace", ...(option.textStyle || {}) },
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
