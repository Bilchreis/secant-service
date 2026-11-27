// History plots: the overview of the whole recording, and the detail of the
// window the chart is zoomed to.
// Methods of the EChartsChart hook (see ./echarts_chart.js).

import {
  formatBucket,
  writeBandPref,
} from "./common";

export const HistoryWindow = {
  // Server events of a historical plot: a zoomed window, or the overview
  // reloaded in the other band mode.
  _listenWindow() {
    this.handleEvent(`window-chart-data-${this.el.id}`, (reply) => this._applyWindow(reply));
    this.handleEvent(`window-chart-error-${this.el.id}`, ({ req }) => {
      if (req !== this._windowReq || this._detailState !== "loading") return;
      this._detailState = "failed";
      this._renderResolution();
    });
    this.handleEvent(`overview-chart-data-${this.el.id}`, (reply) => this._applyOverview(reply));
    this.handleEvent(`overview-chart-error-${this.el.id}`, (reply) => this._overviewFailed(reply));
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
};
