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

let Hooks = {};

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

    this._flushInterval = setInterval(() => this._flushBuffer(), 1000);

    // Register handlers immediately — server may send data before rAF fires (eager push)
    this.handleEvent(`echarts-data-${this.el.id}`, ({ option }) => {
      const { _rangeButtons, _activeButton, _arrayLen, ...echartsOption } = option;
      this._rangeButtons = _rangeButtons || null;
      this._activeButton = _activeButton != null ? _activeButton : null;
      this._arrayLen = _arrayLen != null ? _arrayLen : null;

      this._seriesData = {};
      this._visualMapMin = null;
      this._visualMapMax = null;
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
          echartsOption.visualMap = { ...echartsOption.visualMap, min: this._visualMapMin, max: vMax };
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
      this._chart && this._chart.setOption(echartsOption, { notMerge: true });
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
    requestAnimationFrame(() => {
      if (!this.el) return;
      this._chart = echarts.init(this.el, null, { renderer: "canvas" });

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

  _applyInitialOption(echartsOption) {
    this._chart.setOption(echartsOption, { notMerge: true });
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
      el.className =
        "btn btn-xs " +
        (index === this._activeButton ? "btn-primary" : "btn-neutral");
      el.addEventListener("click", () => {
        this._activeButton = index;
        buttonsEl
          .querySelectorAll("button")
          .forEach((b, i) =>
            b.classList.toggle("btn-primary", i === index),
          );
        buttonsEl
          .querySelectorAll("button")
          .forEach((b, i) =>
            b.classList.toggle("btn-neutral", i !== index),
          );

        const now = Date.now();
        const { xMin, xMax } = this._computeRange(btn, now);
        if (xMin !== null) {
          this._chart.setOption({ xAxis: { min: xMin, max: xMax } });
        } else {
          // "all" — remove explicit range constraints
          this._chart.setOption({ xAxis: { min: null, max: null } });
        }
      });
      buttonsEl.appendChild(el);
    });
  },

  _computeRange(btn, now) {
    if (btn.step === "all") return { xMin: null, xMax: null };
    const msMap = { minute: 60_000, hour: 3_600_000, day: 86_400_000 };
    const windowMs = (msMap[btn.step] || 0) * (btn.count || 1);
    return { xMin: now - windowMs, xMax: now };
  },

  _flushBuffer() {
    if (!this._chart || !this._rangeButtons) return;

    const hasData = Object.values(this._seriesData).some(
      (d) => d.length > 0,
    );
    if (!hasData) return;

    const now = Date.now();


    Object.keys(this._seriesData).forEach((idx) => {
      const d = this._seriesData[idx];
      if (d.length > maxPoints) {
        this._seriesData[idx] = d.slice(d.length - maxPoints);
      }
    });

    const updatedSeries = Object.keys(this._seriesData).map((idx) => ({
      data: this._seriesData[idx],
    }));

    const patch = { series: updatedSeries };

    // Only slide the x-axis window for live mode (has range buttons)
    if (this._rangeButtons && this._activeButton != null) {
      const btn = this._rangeButtons[this._activeButton];
      const { xMin, xMax } = this._computeRange(btn, now);
      if (xMin !== null) patch.xAxis = { min: xMin, max: xMax };
    }

    if (this._arrayLen != null) {
      patch.yAxis = { max: this._arrayLen - 1 };
      patch.animation = false;
      if (this._visualMapMin !== null && this._visualMapMax !== null) {
        const vMax = this._visualMapMax === this._visualMapMin ? this._visualMapMax + 1 : this._visualMapMax;
        patch.visualMap = { min: this._visualMapMin, max: vMax };
      }
    }

    try {
      this._chart.setOption(patch);
    } catch (error) {
      console.error("ECharts flush error:", error);
    }
  },

  destroyed() {
    clearInterval(this._flushInterval);
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
