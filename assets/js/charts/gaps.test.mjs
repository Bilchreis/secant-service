// node --test assets/js/charts/gaps.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";

import { breakHeld, breakLine, breakRows, mergeGaps, spacingGaps } from "./gaps.mjs";

const s = (n) => n * 1000;
// a reading every second from `from` to `to` (seconds), value = its second
const every = (from, to, value = (t) => t) => {
  const out = [];
  for (let t = from; t <= to; t++) out.push([s(t), value(t)]);
  return out;
};
const nulls = (data) => data.filter((p) => p[1] === null).map((p) => p[0]);

test("a raw value line breaks once at a gap, holding its value to the gap start", () => {
  const data = [...every(0, 600), ...every(1200, 1800)];
  const { data: out, breaks } = breakLine(data, [[s(605), s(1200)]]);

  assert.deepEqual(breaks, [s(605)]);
  assert.deepEqual(nulls(out), [s(605)]);
  const k = out.findIndex((p) => p[1] === null);
  assert.deepEqual(out.slice(k - 2, k + 2), [[s(600), 600], [s(605), 600], [s(605), null], [s(1200), 1200]]);
});

test("no gaps, or readings that continue through a recorded gap, draw as today", () => {
  const data = every(0, 100);
  assert.equal(breakLine(data, []).data, data);
  // a 20 s gap recorded, readings 1 s apart throughout it
  assert.deepEqual(nulls(breakLine(data, [[s(40), s(60)]]).data), []);
});

test("a gap below the bucket width of its part is not drawn", () => {
  const data = [...every(0, 100), ...every(130, 200)];
  const gap = [[s(100), s(130)]];
  assert.deepEqual(nulls(breakLine(data, gap).data), [s(100)]);
  assert.deepEqual(nulls(breakLine(data, gap, { widthAt: () => s(900) }).data), []);
});

test("a reading inside the gap (node clock behind) stays, and the line breaks once", () => {
  const data = [...every(0, 600), [s(1197), 1197], ...every(1201, 1300)];
  const { data: out } = breakLine(data, [[s(600), s(1200)]]);
  assert.deepEqual(nulls(out), [s(600)]);
  assert.ok(out.some((p) => p[0] === s(1197) && p[1] === 1197));
});

test("two gaps between the same two points give one break, at the earliest", () => {
  const data = [[0, 1], [s(1000), 2]];
  const { data: out } = breakLine(data, [[s(100), s(200)], [s(500), s(600)]]);
  assert.deepEqual(nulls(out), [s(100)]);
});

test("a held target ends and resumes at every gap, even with no reading between", () => {
  // set to 50 at 0, never changed
  const data = [[0, 50]];
  const out = breakHeld(data, [[s(3600), s(4200)], [s(10800), s(12600)]]);
  assert.deepEqual(out, [
    [0, 50],
    [s(3600), 50],
    [s(3600), null],
    [s(4200), 50],
    [s(10800), 50],
    [s(10800), null],
    [s(12600), 50],
  ]);
});

test("a setpoint reading inside a gap takes effect at the gap end", () => {
  const out = breakHeld([[0, 50], [s(597), 60]], [[s(0.5), s(600)]]);
  assert.deepEqual(out, [[0, 50], [s(0.5), 50], [s(0.5), null], [s(600), 60]]);
});

test("a setpoint pinned at a window start inside a gap draws nothing in the gap", () => {
  // the server pins the value in force at the window start (09:02, inside 09:00-09:10)
  const out = breakHeld([[s(120), 50]], [[0, s(600)]]);
  assert.deepEqual(out, [[s(600), 50]]);
});

test("a gap with no later recording ends the setpoint", () => {
  const out = breakHeld([[0, 50], [s(10), 51]], [[s(100), null]]);
  assert.deepEqual(out, [[0, 50], [s(10), 51], [s(100), 51], [s(100), null]]);
});

test("gaps from every source are joined, never clipped at a seam", () => {
  // overview knows a long gap; a detail reply knows only the part it covers
  assert.deepEqual(mergeGaps([[[s(100), s(500)]], [[s(100), s(500)]], [[s(450), s(700)]]]), [
    [s(100), s(700)],
  ]);
  // a short gap known only from the detail is kept
  assert.deepEqual(mergeGaps([[], [[s(10), s(15)]]]), [[s(10), s(15)]]);
});

test("an open gap ends at a later live close, or at a reply that knows its end", () => {
  assert.deepEqual(mergeGaps([[[s(100), null]]], [{ kind: "close", ms: s(200), at: 1 }]), [[s(100), s(200)]]);
  assert.deepEqual(mergeGaps([[[s(100), null]], [[s(100), s(250)]]]), [[s(100), s(250)]]);
});

test("a live stop and resume, and a close that came before its gap was known", () => {
  assert.deepEqual(
    mergeGaps([], [
      { kind: "open", ms: s(100), at: 1 },
      { kind: "close", ms: s(160), at: 2 },
    ]),
    [[s(100), s(160)]],
  );
  // the close arrived first; the open gap comes with a later reply
  assert.deepEqual(mergeGaps([[[s(100), null]]], [{ kind: "close", ms: s(160), at: 2 }]), [[s(100), s(160)]]);
});

test("a late live stop (a suspend noticed after new readings) still breaks in the right place", () => {
  const data = [...every(0, 50), ...every(700, 720)];
  const gaps = mergeGaps([], [
    { kind: "open", ms: s(50), at: 1 },
    { kind: "close", ms: s(700), at: 2 },
  ]);
  assert.deepEqual(nulls(breakLine(data, gaps).data), [s(50)]);
});

test("the fallback: a spacing of more than 5 poll intervals and a minute is a gap", () => {
  const data = [...every(0, 100), ...every(700, 800)];
  assert.deepEqual(spacingGaps(data, 2000), [[s(100), s(700)]]);
  // exactly a minute apart counts; 59 s doesn't
  assert.deepEqual(spacingGaps([[0, 1], [s(60), 1]], 1000), [[0, s(60)]]);
  assert.deepEqual(spacingGaps([[0, 1], [s(59), 1]], 1000), []);
  // a slow poll interval: no gap
  assert.deepEqual(spacingGaps(data, 300_000), []);
});

test("band rows break where their line broke", () => {
  const rows = [{ t: 0 }, { t: 3600 }, { t: 7200 }, { t: 30000 }, { t: 33600 }];
  assert.deepEqual(breakRows(rows, [7300]), [{ t: 0 }, { t: 3600 }, { t: 7200 }, null, { t: 30000 }, { t: 33600 }]);
  assert.equal(breakRows(rows, []), rows);
});

test("fallback gaps next to each other break each of their pairs", () => {
  const data = [[0, 1], [s(60), 2], [s(120), 3]];
  const gaps = spacingGaps(data, 2000);
  assert.deepEqual(gaps, [[0, s(60)], [s(60), s(120)]]);
  assert.equal(nulls(breakLine(data, gaps).data).length, 2);
});
