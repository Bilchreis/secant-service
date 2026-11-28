// Display labels of custom system plots: a trace's `_label` (e.g. a gas
// name) and an array plot's `_indexLabels` (e.g. "m/z 28" per index). They
// come from node readings, so they are untrusted text: HTML (tooltips)
// escapes them, canvas text (legend, axis labels) and textContent take them
// as they are. Series keep their stable names for updates and the legend's
// hidden lines; labels are display only.
//
// Pure functions, so `node --test` can load this file.

// Text going into tooltip HTML.
export function escHtml(v) {
  return String(v).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

// series name → display label, for the series that have one; null if none
export function labelMap(series) {
  const map = new Map();
  for (const s of series || []) {
    if (s && typeof s._label === "string" && s._label !== "" && s.name != null) map.set(String(s.name), s._label);
  }
  return map.size > 0 ? map : null;
}

// a series' label by its name, else the name
export function labelOf(map, name) {
  return (map && map.get(String(name))) || String(name);
}

// an array index's label, or null without one
export function indexLabel(labels, i) {
  if (!Array.isArray(labels) || !Number.isInteger(i)) return null;
  const l = labels[i];
  return typeof l === "string" && l !== "" ? l : null;
}

// an index as text: its label, else "[i]"
export function indexText(labels, i) {
  return indexLabel(labels, i) ?? `[${i}]`;
}

// an index-axis tick (canvas text): its label, else the number; nothing
// between whole indexes
export function indexTick(labels, v) {
  if (!Number.isInteger(v)) return "";
  return indexLabel(labels, v) ?? String(v);
}
