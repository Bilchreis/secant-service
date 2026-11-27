import * as echarts from "echarts";
import {
  ARRAY_MODE_KEY,
  CHART_PALETTE,
  ChartFlushDriver,
  ChartVisibilityObserver,
  ThemeWatch,
  arrayLineColor,
  escHtml,
  formatAxisNumber,
  formatBucket,
  isDarkTheme,
  maxArrayPoints,
  maxPoints,
  formatTime,
  readArrayMode,
  readBandPref,
  writeBandPref,
} from "./common";

export const EChartsChart = {
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

    // reading picked with the time slider
    this.handleEvent(`array-reading-${this.el.id}`, (snapshot) => {
      // only the reading asked for last (the slider may have moved on)
      if (snapshot.requested !== this._wantT) return;
      this._wantT = null;
      this._applySnapshot(snapshot);
      this._renderScrub();
    });

    // older readings for a live chart whose range got wider: those before
    // `to`, where the buffers started when they were asked for, and before
    // a series' first buffered reading (a setpoint keeps the one in force).
    // Only the answer to the last range click: the range may have changed.
    this.handleEvent(`prepend-chart-data-${this.el.id}`, ({ req, seriesUpdates, arrayLen, from, to, aggregated }) => {
      if (req !== this._rangeReq) return;
      // the thinned readings this reply replaces (kept until it came)
      if (this._rangeTrim != null) this._trimBuffers(this._rangeTrim);
      this._rangeTrim = null;
      (seriesUpdates || []).forEach(({ seriesIndex, data }) => {
        const buffer = this._seriesData[seriesIndex] || [];
        const first = buffer.length ? this._pointTs(buffer[0]) : null;
        const cutoff = first != null && first < to ? first : to;
        const older = data.filter((p) => this._pointTs(p) < cutoff);
        this._seriesData[seriesIndex] = [...older, ...buffer];
        if (this._arrayLen != null && seriesIndex === 0) this._trackHeatRange(older);
      });
      this._coveredFrom = Math.min(this._coveredFrom, from == null ? -Infinity : from);
      // every reading, right up to the ones already raw
      if (!aggregated && this._rawFrom <= to) this._rawFrom = this._coveredFrom;
      this._growArrayLen(arrayLen);
      this._dataDirty = true;
    });

    // the readings of a wider range could not be fetched: a click on its
    // button asks again
    this.handleEvent(`range-chart-error-${this.el.id}`, ({ req }) => {
      if (req === this._rangeReq) this._rangeFailed = true;
    });

    this.handleEvent(`window-chart-data-${this.el.id}`, (reply) => this._applyWindow(reply));
    this.handleEvent(`window-chart-error-${this.el.id}`, ({ req }) => {
      if (req !== this._windowReq || this._detailState !== "loading") return;
      this._detailState = "failed";
      this._renderResolution();
    });
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
      if (!this._chart) return;
      const series = this._windowFetch && this._targetSeriesPatch();
      if (series) this._chart.setOption({ series });
      this._renderResolution();
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

    // zoomed all the way out, or the overview already holds every reading:
    // it is all there is to show
    const raw = this._resolution && !this._resolution.aggregated;
    if (raw || (from <= full[0] && to >= full[1])) {
      this._windowReq++; // a reply still on its way is outdated
      this._detail = null;
      this._detailState = null;
      this._bandCache = null;
      this._drawWindowData();
      return;
    }
    // every reading of this window is already loaded
    const d = this._detail;
    if (d && !d.aggregated && from >= d.from && to <= d.to) {
      // a reply still on its way is for a window the chart has left
      this._windowReq++;
      this._detailState = null;
      this._renderResolution();
      return;
    }

    // some margin on both sides, so that short pans stay inside the detail
    const pad = (to - from) / 2;
    this.pushEventTo(this.el, "fetch-chart-window", {
      from: Math.floor(Math.max(from - pad, full[0])),
      to: Math.ceil(Math.min(to + pad, full[1])),
      req: ++this._windowReq,
      envelope: this._envFlag(),
      gen: this._envGen || 0,
    });
    this._detailState = "loading";
    this._renderResolution();
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
    this._detailState = null;
    this._detail = {
      from,
      to,
      aggregated,
      bucket_ms,
      envelope_bucket_ms,
      series,
      envelopes: this._envelopesBySeries(envelopes),
    };
    // a zoomed window can show a wider array than the thinned overview did:
    // the chart is rebuilt with room for it
    if (this._growsArray(arrayLen)) {
      this._drawWindowData(false);
      this._rebuild();
    } else {
      this._drawWindowData();
    }
  },

  // A reloaded overview in the other envelope mode (after the toggle, or a
  // first load whose mode differs from the browser's preference) replaces
  // the old one; then the zoomed window.
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
    if (this._arrayLen != null) {
      this._visualMapMin = null;
      this._visualMapMax = null;
      this._trackHeatRange(this._seriesData[0] || []);
    }
    this._growsArray(arrayLen);
    this._resolution = { aggregated, bucket_ms, envelope_bucket_ms };
    this._detail = null;
    this._detailState = null;
    this._rebuild();
    this._fetchWindow();
  },

  // the reload failed: stay in the mode the overview holds
  _overviewFailed({ gen }) {
    if (gen !== this._envGen) return;
    this._reloadPending = false;
    writeBandPref(this._overviewEnvelope);
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

  // the array is wider than the chart has room for
  _growsArray(arrayLen) {
    if (this._arrayLen == null || arrayLen == null || arrayLen <= this._arrayLen) return false;
    this._arrayLen = arrayLen;
    return true;
  },

  // overview outside the detail window, detail inside
  _drawWindowData(draw = true) {
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
    // the heatmap's colour scale covers the detail's values too
    // (in Lines mode too: a switch to Heatmap draws them)
    if (this._isArrayPlot() && d && d.series[0]) this._trackHeatRange(d.series[0]);
    if (!draw) return;
    const patch = { series: this._seriesPatch() };
    if (this._isArrayPlot() && this._arrayMode !== "lines") Object.assign(patch, this._heatPatch());
    this._chart.setOption(patch);
    this._renderResolution();
    this._renderEmpty();
  },

  // index axis and colour scale of a heatmap, after its data changed
  _heatPatch() {
    const patch = { yAxis: { max: Math.max(this._arrayLen, 1) - 0.5 } };
    if (this._visualMapMin !== null && this._visualMapMax !== null) {
      const vMax = this._visualMapMax === this._visualMapMin ? this._visualMapMax + 1 : this._visualMapMax;
      patch.visualMap = { min: this._visualMapMin, max: vMax };
    }
    return patch;
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
      return { ...this._dataPatch(d, j), sampling: this._hasBand(m.src) ? "none" : "lttb" };
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
    if (symbol === null) return { data };
    if (this._lone(data)) return { data, showSymbol: true, symbol: "circle" };
    return symbol ? { data, showSymbol: false, symbol } : { data, showSymbol: false };
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
    const rows = this._bandRowsOf(src);
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

  // How the visible window is drawn: "thinned · 15 min intervals" while
  // readings are thinned out, "every reading" once all of them are shown,
  // and whether more detail is on its way or failed to load.
  _renderResolution() {
    const el = document.getElementById(`resolution-${this.el.id}`);
    if (!el) return;
    el.onclick = null;
    el.classList.remove("cursor-pointer", "text-st-error");
    el.removeAttribute("role");
    if (!this._windowFetch || !this._resolution) {
      el.textContent = "";
      el.removeAttribute("title");
      return;
    }
    if (this._detailState === "loading") {
      el.textContent = "loading detail…";
      el.title = "Loading the readings of the zoomed window";
      return;
    }
    if (this._detailState === "failed") {
      el.textContent = "detail failed · retry";
      el.title = "The readings of the zoomed window could not be loaded. Click to try again.";
      el.setAttribute("role", "button");
      el.classList.add("cursor-pointer", "text-st-error");
      el.onclick = () => {
        this._detailState = null;
        this._fetchWindow();
      };
      return;
    }
    // the detail, while the chart shows (part of) its window
    const d = this._detail;
    const visible = this._visibleWindow();
    const inDetail = d && visible && visible[0] >= d.from && visible[1] <= d.to;
    const r = inDetail ? d : this._resolution;
    if (r.envelope_bucket_ms && this._envActive()) {
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
      const time = formatTime(hit.t);
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
    // the buffer too: a rebuild (theme change) draws from it
    this._seriesData[0] = data;
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
      if (band) return this._bandData(src, band);
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
    const time = esc(formatTime(ps[0].value[0]));
    const unit = this._arrayUnit ? ` ${esc(this._arrayUnit)}` : "";
    const fmt = (v) => (typeof v === "number" ? formatAxisNumber(v) : esc(v));
    const val = (p) => fmt(p.value[1]);
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
        this._rebuild();
      });
      el.appendChild(b);
    });
  },

  // heatmap points are [t, index, value]
  _trackHeatRange(data) {
    for (const p of data) {
      const v = p[2];
      // a NaN element (null) has no colour
      if (typeof v !== "number") continue;
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
      el.title = btn.step === "all" ? "Every reading" : `The last ${btn.label}`;
      el.setAttribute("aria-pressed", String(index === this._activeButton));
      this._styleRangeButton(el, index === this._activeButton);
      el.addEventListener("click", () => {
        // the range shown already (a thinned one would be fetched again),
        // unless fetching its readings failed: then this is the retry
        if (index === this._activeButton && !this._rangeFailed) return;
        this._rangeFailed = false;
        this._activeButton = index;
        buttonsEl.querySelectorAll("button").forEach((b, i) => {
          this._styleRangeButton(b, i === index);
          b.setAttribute("aria-pressed", String(i === index));
        });

        const now = Date.now();
        const { xMin: newXMin, xMax: newXMax } = this._computeRange(btn, now);

        // a reply to an earlier click is for another range
        this._rangeReq = (this._rangeReq || 0) + 1;
        this._rangeTrim = null;
        // wider than the buffers hold every reading of: ask for the readings
        // before it (all of them may come back thinned out: so be it)
        if (newXMin === null ? this._coveredFrom > -Infinity : newXMin < this._rawFrom) {
          // thinned readings inside the new range are fetched again, and
          // dropped when the reply comes (so a failed fetch leaves them)
          if (newXMin !== null && this._rawFrom > this._coveredFrom) this._rangeTrim = this._rawFrom;
          const start = this._rangeTrim ?? this._coveredFrom;
          const to = Number.isFinite(start) ? start : now;
          this.pushEventTo(this.el, "fetch-chart-range", { from: newXMin, to: Math.ceil(to), req: this._rangeReq });
        } else if (newXMin !== null) {
          // narrower: drop the readings that left it; a fetch for a wider
          // range still running is of no use
          this.pushEventTo(this.el, "cancel-chart-range", {});
          this._trimBuffers(newXMin);
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

  // Drops what left a live chart's window (`xMin`, or nil for "all": the
  // oldest beyond the point cap). From then on the buffers hold every
  // reading from `xMin` on.
  _trimBuffers(xMin) {
    if (xMin !== null) {
      Object.keys(this._seriesData).forEach((idx) => this._trimBefore(idx, xMin));
      this._coveredFrom = Math.max(this._coveredFrom, xMin);
    } else {
      Object.keys(this._seriesData).forEach((idx) => {
        const d = this._seriesData[idx];
        const cap = this._isArrayPlot() ? maxArrayPoints : maxPoints;
        if (d.length > cap) {
          this._seriesData[idx] = d.slice(d.length - cap);
          this._coveredFrom = Math.max(this._coveredFrom, this._pointTs(this._seriesData[idx][0]));
        }
      });
    }
    this._rawFrom = Math.max(this._rawFrom, this._coveredFrom);
  },

  _flushBuffer() {
    if (!this._chart || !this._rangeButtons) return;

    const now = Date.now();
    const btn = this._activeButton != null ? this._rangeButtons[this._activeButton] : null;
    const range = btn ? this._computeRange(btn, now) : { xMin: null, xMax: null };

    // Trimming runs off screen too, so a hidden chart's buffers stay bounded;
    // drawing waits until it is visible (the data stays dirty until then).
    if (this._dataDirty) this._trimBuffers(range.xMin);
    if (!this._isVisible) return;

    // Slide the x-axis window every tick, even with no new data — this is what
    // makes a live chart visibly advance with wall-clock time while idle.
    const patch = {};
    if (range.xMin !== null) patch.xAxis = this._xAxisPatch({ min: range.xMin, max: range.xMax });

    // The rest (rebuilding series + heatmap extras) is the expensive part —
    // an ECharts re-diff over up to maxPoints per series — so only do it
    // when data has actually changed since the last flush.
    if (this._dataDirty) {
      this._dataDirty = false;
      if (this._isArrayPlot() && this._arrayMode === "lines" && this._linesCount !== this._arrayLen) {
        // the array got longer or shorter: rebuild the line series
        this._rebuild();
        return;
      }
      patch.series = this._chartSeriesData().map((data, j) => this._dataPatch(data, j));
      if (this._isArrayPlot() && this._arrayMode !== "lines") Object.assign(patch, this._heatPatch());
      this._renderEmpty();
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
