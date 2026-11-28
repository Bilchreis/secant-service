// Display labels of custom system plots (./labels.mjs).
// Run: node --test assets/js/charts/labels.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";

import { escHtml, indexLabel, indexText, indexTick, labelMap, labelOf } from "./labels.mjs";

test("a label with markup is escaped for tooltips and raw for canvas", () => {
  const labels = labelMap([{ name: "value.composition[0]", _label: "<b>N2</b>" }]);
  // canvas text (the legend) and textContent take it as it is
  assert.equal(labelOf(labels, "value.composition[0]"), "<b>N2</b>");
  // tooltip HTML escapes it
  assert.equal(escHtml(labelOf(labels, "value.composition[0]")), "&lt;b&gt;N2&lt;/b&gt;");
});

test("series without a label keep their name; no labels, no map", () => {
  const labels = labelMap([
    { name: "value.composition[0]", _label: "N2" },
    { name: "value.total_flow" },
    { name: "x", _label: "" },
  ]);
  assert.equal(labelOf(labels, "value.composition[0]"), "N2");
  assert.equal(labelOf(labels, "value.total_flow"), "value.total_flow");
  assert.equal(labelOf(labels, "x"), "x");
  assert.equal(labelMap([{ name: "value" }]), null);
  assert.equal(labelOf(null, "value"), "value");
});

test("equal labels stay apart: lines are found by name", () => {
  const labels = labelMap([
    { name: "value.composition[0]", _label: "N2" },
    { name: "value.composition[1]", _label: "N2" },
  ]);
  assert.equal(labels.size, 2);
});

test("an index shows its label, else its number", () => {
  const labels = ["m/z 1", "m/z 2", null, ""];
  assert.equal(indexLabel(labels, 1), "m/z 2");
  assert.equal(indexLabel(labels, 2), null);
  assert.equal(indexLabel(labels, 9), null);
  assert.equal(indexLabel(null, 0), null);
  assert.equal(indexText(labels, 0), "m/z 1");
  assert.equal(indexText(labels, 3), "[3]");
  assert.equal(indexTick(labels, 0), "m/z 1");
  assert.equal(indexTick(labels, 5), "5");
  // between whole indexes the axis shows nothing
  assert.equal(indexTick(labels, 0.5), "");
  assert.equal(indexTick(null, 2), "2");
});
