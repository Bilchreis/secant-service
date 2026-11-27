// Shared by the chart hooks: theme, palette, number formatting and the
// timers and observers that keep many charts on a page cheap.

export const maxPoints = 20000;
// array plots buffer one point per element per reading
export const maxArrayPoints = 400000;

// Heatmap / Lines for 1-D array plots, remembered per browser.
export const ARRAY_MODE_KEY = "secant:array-mode";
export const readArrayMode = () => {
  try {
    return localStorage.getItem(ARRAY_MODE_KEY) === "lines" ? "lines" : "heatmap";
  } catch (_e) {
    return "heatmap";
  }
};

// min/mean/max band on historical number lines, on by default and
// remembered per browser.
const BAND_KEY = "secant:envelope";
export const readBandPref = () => {
  try {
    return localStorage.getItem(BAND_KEY) !== "off";
  } catch (_e) {
    return true;
  }
};
export const writeBandPref = (on) => {
  try {
    localStorage.setItem(BAND_KEY, on ? "on" : "off");
  } catch (_e) {}
};

// Line colours for array elements: index 0 → violet … last → rose, so the
// order reads at a glance; all stops stay visible on light and dark.
export const ARRAY_LINE_STOPS = [
  [139, 92, 246],
  [56, 189, 248],
  [16, 185, 129],
  [245, 158, 11],
  [244, 63, 94],
];
// Text from the node's description (units, names) going into tooltip HTML.
export function escHtml(v) {
  return String(v).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

// Axis and scale labels that stay readable for tiny or huge values
// (e.g. partial pressures of 1e-13 mbar): exponent form outside 1e-3 … 1e6.
export function formatAxisNumber(v) {
  if (typeof v !== "number" || !isFinite(v)) return String(v);
  if (v === 0) return "0";
  const a = Math.abs(v);
  if (a < 1e-3 || a >= 1e6) {
    const [m, e] = v.toExponential(2).split("e");
    return `${Number(m)}e${Number(e)}`;
  }
  return String(Number(v.toPrecision(4)));
}

export function arrayLineColor(i, n) {
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
export const ChartFlushDriver = {
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
export const ChartVisibilityObserver = new IntersectionObserver((entries) => {
  entries.forEach((entry) => {
    if (entry.target._echartsHook) {
      entry.target._echartsHook._isVisible = entry.isIntersecting;
    }
  });
});

// ---------------------------------------------------------------------------
// Theme helpers: charts follow the light/dark theme of the page
// ---------------------------------------------------------------------------

export const prefersDark = window.matchMedia("(prefers-color-scheme: dark)");

export function isDarkTheme() {
  const theme = document.documentElement.getAttribute("data-theme");
  if (theme === "dark") return true;
  if (theme === "light") return false;
  return prefersDark.matches;
}

// Series palette: HZB light blue first, then colours that stay apart in both
// themes (and differ in lightness, not only hue).
export const CHART_PALETTE = ["#009ee0", "#8b5cf6", "#f59e0b", "#10b981", "#f43f5e", "#a3a3a8", "#ec4899", "#84cc16"];

// Notify mounted charts when the theme changes (theme toggle or OS setting).
export const ThemeWatch = {
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

// Width of a time bucket for the resolution label: 900000 → "15 min"
export const formatBucket = (ms) => {
  const units = [[86_400_000, "d"], [3_600_000, "h"], [60_000, "min"], [1_000, "s"]];
  for (const [size, unit] of units) {
    if (ms >= size) return `${+(ms / size).toFixed(1)} ${unit}`;
  }
  return `${ms} ms`;
};

// Time of a reading for tooltips and labels: the time of day for today,
// with the date for other days (long recordings span several).
export function formatTime(ms) {
  const d = new Date(ms);
  return d.toDateString() === new Date().toDateString()
    ? d.toLocaleTimeString([], { hour12: false })
    : d.toLocaleString([], { hour12: false });
}
