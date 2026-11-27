// Long arrays: the latest reading as a line over the index, and a time
// slider to step through the stored readings.
// Methods of the EChartsChart hook (see ./echarts_chart.js).

export const ArrayLatest = {
  // Server events of a long-array plot (see the time slider below).
  _listenArrayLatest() {
    // reading picked with the time slider
    this.handleEvent(`array-reading-${this.el.id}`, (snapshot) => {
      // only the reading asked for last (the slider may have moved on)
      if (snapshot.requested !== this._wantT) return;
      this._wantT = null;
      this._applySnapshot(snapshot);
      this._renderScrub();
    });
  },

  // A long array's new reading: onto the time slider, and shown when the
  // slider follows the latest one.
  _onLatestReading(snapshot) {
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
      series: [this._dataPatch(data, 0)],
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
};
