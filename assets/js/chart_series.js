// Helpers for live chart series data. Parameter values are stored only when
// they change, so the last point of a series is the value still in effect.

// Timestamp of a point, regardless of series data shape: plain [ts, ...]
// arrays (line/scatter/heatmap) or enum's {value: [ts, y], ...} objects.
export function pointTs(point) {
  if (!point) return null;
  return Array.isArray(point) ? point[0] : point.value ? point.value[0] : null;
}

// Drop points before xMin, but keep the last one: it holds the value still in
// effect at the window's left edge.
export function trimBefore(data, xMin) {
  if (data.length === 0 || pointTs(data[0]) >= xMin) return data;
  const cutoff = data.findIndex((p) => pointTs(p) >= xMin);
  return cutoff === -1 ? data.slice(-1) : data.slice(cutoff - 1);
}

// Data for display: an unmarked point at `now` repeating the last value, so
// an unchanged value reaches the right edge of a live chart.
export function withTail(data, now) {
  if (data.length === 0) return data;
  const last = data[data.length - 1];
  if (pointTs(last) >= now) return data;
  const tail = Array.isArray(last)
    ? { value: [now, ...last.slice(1)], symbol: "none" }
    : { ...last, value: [now, last.value[1]], symbol: "none" };
  return [...data, tail];
}
