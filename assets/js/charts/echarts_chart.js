import * as echarts from "echarts";
import {
  CHART_PALETTE,
  ChartFlushDriver,
  ChartVisibilityObserver,
  formatAxisNumber,
  isDarkTheme,
  readArrayMode,
  ThemeWatch,
} from "./common";
import { HistoryWindow } from "./history_window";
import { Bands } from "./bands";
import { Arrays } from "./arrays";
import { ArrayLatest } from "./array_latest";
import { Live } from "./live";
import { Setpoints } from "./setpoints";
import { Gaps } from "./gaps.mjs";

// The chart hook of every plot (live and history; numbers, enums, arrays,
// structs). Its methods are split by concern over the modules imported
// above; they share one `this`, the hook.
export const EChartsChart = {
  ...HistoryWindow,
  ...Bands,
  ...Arrays,
  ...ArrayLatest,
  ...Live,
  ...Setpoints,
  // after Setpoints: its _drawnData breaks the lines, then holds setpoints
  ...Gaps,

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
      const { _rangeButtons, _activeButton, _arrayLen, _arrayUnit, _arrayName, _arrayLatest, _arrayTimes, _windowFetch, _envelope, _envelopes, _gaps, ...echartsOption } = option;
      // number-line plots: the gaps of their session, where the lines break
      this._resetGaps(_gaps);
      // historical plots: the server thins out long recordings and
      // sends more detail for the window the chart is zoomed to
      this._windowFetch = !!_windowFetch;
      this._resolution = _windowFetch || null;
      this._overview = null;
      this._detail = null;
      this._windowReq = 0;
      this._detailState = null; // "loading" | "failed" while a zoomed window is on its way
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
      // live plots: the time from which the buffers hold every reading
      // (the range shown at load, or all of them)
      const xAxis0 = Array.isArray(echartsOption.xAxis) ? echartsOption.xAxis[0] : echartsOption.xAxis;
      this._coveredFrom = xAxis0 && xAxis0.min != null ? xAxis0.min : -Infinity;
      // ... and from which those readings are not thinned out (a wider range
      // can come back thinned, see `fetch-chart-range`)
      this._rawFrom = this._coveredFrom;
      // a new chart: its time range slider starts closed
      const sliderBtn = document.getElementById(`rangeslider-btn-${this.el.id}`);
      if (sliderBtn) sliderBtn.setAttribute("aria-pressed", "false");
      // Seed min/max from initial data and bake into the option (visualMap present = heatmap)
      if (echartsOption.visualMap && this._arrayLen != null) {
        this._trackHeatRange(this._seriesData[0] || []);
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

    this._listenArrayLatest();
    this._listenLive();
    this._listenWindow();
    this._listenGaps();

    this._toggleRangeslider = (e) => {
      if (e.target.dataset.chartId !== this.el.id || !this._chart) return;
      this._setSlider(!this._hasSlider());
    };
    document.addEventListener("toggle-rangeslider", this._toggleRangeslider);

    this._onCloseModal = () => {
      if (this.el.closest("dialog")) {
        this._disposeChart();
      }
    };
    window.addEventListener("myapp:close-modal", this._onCloseModal);

    // Defer echarts.init until after paint so clientWidth/clientHeight are non-zero
    this._onThemeChange = () => this._rebuild({ reinit: true });
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

  // The data of every drawn series, plus whether a line is sampled: not
  // while it shows bucket means (each one counts), as today otherwise.
  _seriesPatch() {
    const data = this._chartSeriesData();
    if (!this._envActive()) return data.map((d, j) => this._dataPatch(d, j));
    const map = this._seriesMap || [];
    return data.map((d, j) => {
      const m = map[j];
      if (!m || m.band || !this._bandParent(m)) return this._dataPatch(d, j);
      return { ...this._dataPatch(d, j), sampling: this._sampling(d, this._hasBand(m.src)) };
    });
  },

  // exactly one reading with a value (a gap in an array is a null)
  _lone(data) {
    let n = 0;
    for (const p of data) {
      if (p != null && (!Array.isArray(p) || p[1] != null) && ++n > 1) return false;
    }
    return n === 1;
  },

  // The new data of drawn series `j`. Lines show no marker on their
  // readings, so a lone reading gets one, or it would not show at all
  // (array lines have no symbol, not even on hover: it gets one, and gets
  // its own back with the next reading).
  _dataPatch(data, j) {
    const symbol = this._symbols ? this._symbols[j] : undefined;
    // a line with breaks is not sampled (see ./gaps.mjs)
    if (this._gapsOn && !(this._seriesMap && this._seriesMap[j] && this._seriesMap[j].band)) {
      return { ...this._gapDataPatch(data, symbol), sampling: this._sampling(data, false) };
    }
    return this._dataPatchOf(data, symbol);
  },

  _dataPatchOf(data, symbol) {
    if (symbol === null) return { data };
    if (this._lone(data)) return { data, showSymbol: true, symbol: "circle" };
    return symbol ? { data, showSymbol: false, symbol } : { data, showSymbol: false };
  },

  // --- Rebuilding -----------------------------------------------------------

  // Draws the chart from scratch: on a new plot, when bands appear or go,
  // the array grew, Heatmap/Lines switched, or the theme changed (`reinit`:
  // a new ECharts instance in the new theme). Unless `fresh`, the view
  // stays: zoom, the legend's hidden series and an open time range slider.
  _rebuild({ reinit = false, fresh = false } = {}) {
    if (!this._chart || !this._lastOption) return;
    const current = fresh ? {} : this._chart.getOption() || {};
    const shown = !fresh && this._windowFetch ? this._visibleWindow() : null;
    const full = this._overviewExtent();
    const legend = (current.legend || [])[0];
    const selected = legend && legend.selected;
    const slider = (current.dataZoom || []).some((dz) => dz && dz.type === "slider");

    if (reinit) {
      this._chart.dispose();
      this._chart = this._initChart();
      this._heatTipBound = false;
    }
    this._heatCache = {};
    let option = this._themed(this._composeOption(this._lastOption));
    if (selected && option.legend && !Array.isArray(option.legend)) {
      option = { ...option, legend: { ...option.legend, selected } };
    }
    this._chart.setOption(option, { notMerge: true });
    // each drawn line's own marker, for _dataPatch; null for series that
    // draw no reading as a point (band helpers are stacked, heatmaps and
    // state bands are no lines)
    // (undefined: the theme's default)
    this._symbols = (option.series || []).map((s) => (s && s.type === "line" && !s.stack ? s.symbol : null));
    if (slider) this._setSlider(true);
    if (shown && full && (shown[0] > full[0] || shown[1] < full[1])) {
      this._chart.dispatchAction({ type: "dataZoom", startValue: shown[0], endValue: shown[1] });
    }
    this._bindHeatTooltip();
    // the buffers as they are now (the option holds the data of the load),
    // with a heatmap's index axis and colour scale to match
    const patch = { series: this._seriesPatch() };
    if (this._isArrayPlot() && this._arrayMode !== "lines") Object.assign(patch, this._heatPatch());
    this._chart.setOption(patch);
    this._renderArrayModeButtons();
    this._renderEnvelopeToggle();
    this._renderResolution();
    this._renderEmpty();
    // a live chart's time window is where the next flush puts it
    this._dataDirty = true;
    this._flushBuffer();
  },

  _hasSlider() {
    return (((this._chart && this._chart.getOption()) || {}).dataZoom || []).some((dz) => dz && dz.type === "slider");
  },

  // Opens or closes the time range slider under the (last) time axis.
  _setSlider(on) {
    // all time axes of a multi-grid (struct) plot move together
    const axes = this._xAxisCount > 1 ? [...Array(this._xAxisCount).keys()] : 0;
    const current = this._chart.getOption();
    const zooms = (current.dataZoom || [])
      .filter((dz) => dz && dz.type !== "slider")
      .map((dz) => ({ type: dz.type, xAxisIndex: axes, filterMode: dz.filterMode }));
    const filterMode = zooms.length ? zooms[0].filterMode : undefined;
    const update = {
      dataZoom: on ? [...zooms, { type: "slider", xAxisIndex: axes, bottom: 8, filterMode }] : zooms,
    };
    // make room below the time axis so the slider doesn't cover its labels
    if (this._xAxisCount === 1) {
      const grid = (current.grid || [])[0] || {};
      if (on && this._gridBottom == null) this._gridBottom = typeof grid.bottom === "number" ? grid.bottom : 40;
      update.grid = { bottom: on ? this._gridBottom + 40 : (this._gridBottom ?? 40) };
      if (!on) this._gridBottom = null;
    }
    this._chart.setOption(update, { replaceMerge: ["dataZoom"] });
  },

  // "No readings" over a chart with nothing to draw yet.
  _renderEmpty() {
    const empty =
      !this._arrayLatest && Object.values(this._seriesData).every((d) => !d || d.length === 0);
    if (!empty) {
      if (this._emptyNote) this._emptyNote.style.display = "none";
      return;
    }
    if (!this._emptyNote || !this._emptyNote.isConnected) {
      this._emptyNote = document.createElement("div");
      this._emptyNote.className =
        "pointer-events-none absolute inset-0 flex items-center justify-center text-xs text-muted";
      this.el.style.position = this.el.style.position || "relative";
      this.el.appendChild(this._emptyNote);
    }
    this._emptyNote.textContent = this._rangeButtons ? "No readings in this range yet" : "No readings recorded";
    this._emptyNote.style.display = "";
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
      // a held line (a setpoint) runs to the end; a target is also muted
      if (s && (s._held || s._target)) {
        this._targetIdx.add(String(s._src != null ? s._src : i));
        const color = s._target && muted ? { lineStyle: { ...(s.lineStyle || {}), color: muted }, itemStyle: { ...(s.itemStyle || {}), color: muted } } : {};
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

  // The option to draw, with envelope bands where they are on.
  _composeOption(option) {
    return this._withBands(this._composeBase(option));
  },

  // The data of each drawn series, from the buffers: as buffered, or one
  // element of an array buffer (lines mode).
  _chartSeriesData() {
    const map = this._seriesMap;
    if (!map) return Object.keys(this._seriesData).map((idx) => this._drawnData(idx));
    const split = {};
    return map.map(({ src, elem, band }) => {
      if (band) return this._bandData(src, band);
      if (elem == null) return this._drawnData(src);
      if (!split[src]) split[src] = this._splitArray(this._seriesData[src] || [], this._elementCount(src));
      return split[src][elem] || [];
    });
  },

  _applyInitialOption(echartsOption) {
    this._lastOption = echartsOption;
    this._gridBottom = null;
    this._rebuild({ fresh: true });
    this._renderScrub();
    this._renderRangeButtons();
    // the browser's preference differs from the server's default
    if (this._envMeta && this._envFlag() !== this._overviewEnvelope) this._onEnvFlagChange();
  },

  _disposeChart() {
    if (this._chart) {
      this._chart.dispose();
      this._chart = null;
    }
  },

  // Timestamp of a buffered point, regardless of series data shape:
  // plain [ts, ...] arrays (line/scatter/heatmap) or enum's {value: [ts, y], ...} objects.
  _pointTs(point) {
    if (!point) return null;
    return Array.isArray(point) ? point[0] : (point.value ? point.value[0] : null);
  },

  _pointValue(point) {
    return Array.isArray(point) ? point[1] : point.value[1];
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
