// Live plots: the range buttons, older readings for a wider range, and the
// buffers that the flush driver draws.
// Methods of the EChartsChart hook (see ./echarts_chart.js).

import {
  maxArrayPoints,
  maxPoints,
} from "./common";

export const Live = {
  // Server events of a live plot: new readings, and older ones for a
  // wider range.
  _listenLive() {
    // older readings for a live chart whose range got wider: those before
    // `to`, where the buffers started when they were asked for, and before
    // a series' first buffered reading (a setpoint keeps the one in force).
    // Only the answer to the last range click: the range may have changed.
    this.handleEvent(`prepend-chart-data-${this.el.id}`, ({ req, seriesUpdates, arrayLen, from, to, aggregated, bucket_ms, gaps }) => {
      this._addGaps({ gaps });
      if (req !== this._rangeReq) return;
      // the thinned readings this reply replaces (kept until it came)
      if (this._rangeTrim != null) this._trimBuffers(this._rangeTrim);
      this._rangeTrim = null;
      // a thinned range: its gaps are judged at its bucket width (./gaps.mjs).
      // Each series takes the reply's readings before its own first one:
      // that part is new, and replaces the widths of ranges lying wholly
      // inside it (the widest series' part counts)
      if (this._liveRanges) {
        const lo = from == null ? -Infinity : from;
        const hi = Math.max(
          lo,
          ...(seriesUpdates || []).map(({ seriesIndex }) => {
            const buffer = this._seriesData[seriesIndex] || [];
            const first = buffer.length ? this._pointTs(buffer[0]) : null;
            return first != null && first < to ? first : to;
          }),
        );
        this._liveRanges = this._liveRanges.filter((r) => !(r.from >= lo && r.to <= hi));
        if (aggregated && bucket_ms) this._liveRanges.push({ from: lo, to: hi, bucket_ms });
      }
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

    this.handleEvent(`extend-chart-${this.el.id}`, ({ seriesUpdates, arrayLen, snapshot }) => {
      if (snapshot) {
        this._onLatestReading(snapshot);
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

  // drop readings left of the window; a setpoint keeps the one still in force
  _trimBefore(idx, xMin) {
    const d = this._seriesData[idx];
    if (d.length === 0 || this._pointTs(d[0]) >= xMin) return;
    let cutoff = d.findIndex((p) => this._pointTs(p) >= xMin);
    if (cutoff === -1) cutoff = d.length;
    if (this._targetIdx && this._targetIdx.has(String(idx))) cutoff -= 1;
    if (cutoff > 0) this._seriesData[idx] = d.slice(cutoff);
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
};
