// Array plots: a time × index heatmap, or one line per element ("lines"
// mode), also for the array fields of a struct.
// Methods of the EChartsChart hook (see ./echarts_chart.js).

import {
  ARRAY_MODE_KEY,
  arrayLineColor,
  escHtml,
  formatAxisNumber,
  formatBucket,
  formatTime,
} from "./common";
import { gapAt, gapText } from "./gaps.mjs";
import { indexText, indexTick } from "./labels.mjs";

export const Arrays = {
  // the array is wider than the chart has room for
  _growsArray(arrayLen) {
    if (this._arrayLen == null || arrayLen == null || arrayLen <= this._arrayLen) return false;
    this._arrayLen = arrayLen;
    return true;
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

        // readings: [first item, timestamp] in time order; the last one
        // holds until now (live) or for one typical interval (./gaps.mjs)
        const { starts, times, held } = this._heatRows((j) => api.value(0, j), n, live);
        const g = times.length;
        // rows end at recording gaps (./gaps.mjs)
        const ends = this._heatRowEnds(times, held);

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
    zr.on("mousemove", (e) => {
      this._pointer = { x: e.offsetX, y: e.offsetY };
      this._showReadout();
    });
    zr.on("globalout", () => {
      // the class stays until the next move: ECharts fades its tooltip out
      // after the pointer left, and it would flash up meanwhile
      this._pointer = null;
      if (this._heatTip) this._heatTip.style.display = "none";
    });
    // after every redraw (a live tick that only moves the axis too): the
    // region under a resting pointer may have moved or closed
    this._chart.on("finished", () => this._pointer && this._showReadout());
  },

  // The readout at the pointer: a heatmap cell's reading, else the gap
  // region's description (hiding the axis tooltip), else nothing.
  _showReadout() {
    const p = this._pointer;
    const hit = p && this._heatCellAt(p.x, p.y);
    const gap = p && !hit && this._gapAtPixel(p.x, p.y);
    this.el.classList.toggle("gap-hover", !!gap);
    if (!hit && !gap) {
      if (this._heatTip) this._heatTip.style.display = "none";
      return;
    }
    if (!this._heatTip || !this._heatTip.isConnected) {
      this._heatTip = document.createElement("div");
      this._heatTip.className =
        "pointer-events-none absolute z-10 rounded border border-line bg-base-100 px-2 py-1 font-mono text-[11px] whitespace-pre-wrap shadow-sm";
      this.el.style.position = this.el.style.position || "relative";
      this.el.appendChild(this._heatTip);
    }
    if (hit) {
      const time = formatTime(hit.t);
      const unit = this._arrayUnit ? ` ${this._arrayUnit}` : "";
      const value = typeof hit.v === "number" ? formatAxisNumber(hit.v) : hit.v;
      // textContent: a system plot's index label goes in as it is
      const index = indexText(this._indexLabels, hit.i);
      this._heatTip.textContent = `${time}  ${index}  ${value}${unit}${hit.label ? `  ${hit.label}` : ""}`;
    } else {
      this._heatTip.textContent = gapText(gap, Date.now(), { time: formatTime, duration: formatBucket });
    }
    this._heatTip.style.display = "";
    // within the chart: a gap's long line wraps in a narrow panel. Measured
    // at the left edge, so the last position doesn't squeeze it.
    this._heatTip.style.maxWidth = `${Math.max(120, this.el.clientWidth - 8)}px`;
    this._heatTip.style.left = "0px";
    const left = Math.min(p.x + 12, this.el.clientWidth - this._heatTip.offsetWidth - 4);
    this._heatTip.style.left = `${Math.max(0, left)}px`;
    const top = Math.min(p.y - 30, this.el.clientHeight - this._heatTip.offsetHeight - 4);
    this._heatTip.style.top = `${Math.max(0, top)}px`;
  },

  // The marked gap at a pixel inside the plot area, if any (./gaps.mjs)
  _gapAtPixel(x, y) {
    const regions = this._gapsOn ? this._gapRegions() : [];
    if (regions.length === 0 || !this._chart.containPixel({ gridIndex: 0 }, [x, y])) return null;
    const t = this._chart.convertFromPixel({ xAxisIndex: 0 }, x);
    return Number.isFinite(t) ? gapAt(t, regions) : null;
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

  _isArrayPlot() {
    return this._arrayLen != null;
  },

  // The option to draw: the server's heatmap option, or for "lines" one line
  // per array element built from the same buffered points.
  _composeBase(option) {
    // which buffer each drawn series shows; null = one series per buffer
    this._seriesMap = null;
    // a system plot's labelled array index (e.g. "m/z 28" per element)
    this._indexLabels = option._indexLabels || null;
    if (this._arrayLatest) {
      const labels = this._indexLabels;
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
        // the index axis's labels are canvas text: raw
        ...(labels ? { xAxis: { ...option.xAxis, axisLabel: { formatter: (v) => indexTick(labels, v) } } } : {}),
        tooltip: {
          ...option.tooltip,
          formatter: (ps) => {
            const p = ps && ps[0];
            return p ? `${escHtml(indexText(labels, p.value[0]))}  ${formatAxisNumber(p.value[1])}${unit}` : "";
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
    // the element's name: a system plot's index label, by the element the
    // line draws (series keep their "[i]" names)
    const name = (p) => {
      const m = this._seriesMap && this._seriesMap[p.seriesIndex];
      return m && m.elem != null && this._indexLabels ? indexText(this._indexLabels, m.elem) : p.seriesName;
    };
    const hit = this._hoverSeries != null && ps.find((p) => p.seriesIndex === this._hoverSeries);
    if (hit) {
      return (
        `<div>${time}</div>` +
        `<div style="font-size:13px;font-weight:600"><span style="color:${hit.color}">●</span> ` +
        `${esc(name(hit))} ${val(hit)}${unit}</div>`
      );
    }
    const seen = new Set();
    const rows = ps
      .filter((p) => !seen.has(p.seriesName) && seen.add(p.seriesName))
      .map((p) => `<span style="color:${p.color}">●</span> ${esc(name(p))} ${val(p)}`)
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
};
