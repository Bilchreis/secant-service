// node --test assets/js/charts/gaps.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";

import {
  Gaps,
  breakHeld,
  breakLine,
  breakRows,
  clipRowEnds,
  gapAt,
  gapText,
  isolatedPoints,
  mergeGaps,
  regionMarks,
  spacingGaps,
} from "./gaps.mjs";

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

  // as the hook draws it: through _broken, with the session's (no) gaps
  const hook = {
    ...Gaps,
    _seriesData: { 0: data },
    _gapsOn: true,
    _gapSets: [[]],
    _gapLive: [],
    _gapFallback: { 0: 2000 },
    _rangeButtons: null,
    _resolution: null,
    _detail: null,
  };
  assert.equal(nulls(hook._broken(0).data).length, 2);
});

test("a reading a break left on its own is marked", () => {
  const data = [...every(0, 10), [s(15), 5], [s(15), null], [s(700), 7]];
  // the reading after the break, with nothing after it yet
  assert.deepEqual([...isolatedPoints(data)], [13]);
  assert.equal(isolatedPoints(every(0, 10)).size, 0);
});

// -- heatmap rows (array plots) ----------------------------------------------

// row ends as the heatmap holds them: until the next reading, the last for `lastHold`
const holds = (times, lastHold) => times.map((t, k) => (k + 1 < times.length ? times[k + 1] : t + lastHold));

test("a heatmap row ends at the gap start, and the rows resume after it", () => {
  // a 20-element array every 10 s; a 5-minute gap after 600 s
  const times = [];
  for (let t = 0; t <= 600; t += 10) times.push(s(t));
  for (let t = 900; t <= 1200; t += 10) times.push(s(t));
  const ends = clipRowEnds(times, holds(times, s(10)), [[s(605), s(900)]]);
  const k = times.indexOf(s(600));
  assert.equal(ends[k], s(605));
  assert.equal(ends[k - 1], s(600));
  assert.equal(ends[k + 1], s(910));
});

test("rows of readings stamped inside a gap end at their own times", () => {
  const times = [0, s(120), s(240), s(400)];
  const ends = clipRowEnds(times, holds(times, s(10)), [[s(60), s(360)]]);
  assert.deepEqual(ends, [s(60), s(120), s(240), s(410)]);
});

test("a short gap before a long one: the row ends at the long one", () => {
  const ends = clipRowEnds([0, s(1000)], holds([0, s(1000)], s(10)), [[s(10), s(11)], [s(100), s(700)]]);
  assert.equal(ends[0], s(100));
});

test("short or coarse gaps, and readings that go on through one, clip nothing", () => {
  const times = [0, s(1000)];
  // 30 s gap at a 15-minute bucket width
  assert.deepEqual(clipRowEnds(times, holds(times, s(10)), [[s(100), s(130)]], { widthAt: () => s(900) }), [
    s(1000),
    s(1010),
  ]);
  // readings 1 s apart through a closed 20 s recorded gap
  const every1 = [];
  for (let t = 0; t <= 60; t++) every1.push(s(t));
  const h = holds(every1, s(1));
  assert.deepEqual(clipRowEnds(every1, h, [[s(20), s(40)]]), h);
  // no gaps
  assert.equal(clipRowEnds(times, h, []), h);
});

test("a live last row ends at an open gap at once; a historical one is never lengthened", () => {
  const now = s(1000);
  // open gap started 1 s ago
  assert.deepEqual(clipRowEnds([s(990)], [now], [[s(999), null]]), [s(999)]);
  // a reading stamped after the open gap's start (node clock ahead): its own time
  assert.deepEqual(clipRowEnds([s(990)], [now], [[s(980), null]]), [s(990)]);
  // the session ended long after the historical row's end: unchanged
  assert.deepEqual(clipRowEnds([s(100)], [s(110)], [[s(5000), null]]), [s(110)]);
});

// a fake array hook with the gap state of a plot that has gaps
const arrayHook = (gaps, extra = {}) => ({
  ...Gaps,
  _isArrayPlot: () => true,
  _arrayMode: "lines",
  _gapsOn: true,
  _gapSets: [gaps],
  _gapLive: [],
  _gapFallback: {},
  _rangeButtons: null,
  _resolution: null,
  _detail: null,
  _lone: (data) => data.filter((p) => p[1] != null).length === 1,
  _dataPatchOf: (data) => ({ data, showSymbol: false }),
  ...extra,
});

test("an array plot's cell buffer never gets line breaks", () => {
  const cells = [[0, 0, 1], [0, 1, 2], [s(500), 0, 3], [s(500), 1, 4]];
  const hook = arrayHook([[s(10), s(400)]], { _seriesData: { 0: cells } });
  assert.equal(hook._broken(0).data, cells);
});

test("element lines break, with a circle on a lone reading", () => {
  const hook = arrayHook([[s(10), s(400)]], {
    _seriesMap: [{ src: 0, elem: 0 }],
    _symbols: ["none"],
  });
  const line = hook._elementLine([[0, 1], [s(5), 2], [s(500), 3]]);
  assert.deepEqual(nulls(line), [s(10)]);
  const patch = hook._gapPatch(line, 0);
  const lone = line.findIndex((p) => p[0] === s(500));
  assert.equal(patch.symbol(null, { dataIndex: lone }), "circle");
  assert.equal(patch.symbol(null, { dataIndex: 0 }), "none");
  assert.equal(patch.sampling, "none");
});

test("a span-less array in Lines mode (no gaps) and a heatmap get the plain patch", () => {
  const withNaN = [[0, 1], [s(1), null], [s(2), 3], [s(3), null]];
  const lines = arrayHook([], { _seriesMap: [{ src: 0, elem: 0 }], _symbols: ["none"] });
  assert.equal(lines._gapPatch(withNaN, 0), null);
  assert.equal(lines._elementLine(withNaN), withNaN);
  const heat = arrayHook([[0, s(10)]], { _arrayMode: "heatmap", _seriesMap: null, _symbols: [null] });
  assert.equal(heat._gapPatch(withNaN, 0), null);
});

test("a span-less number line with fallback breaks keeps its gap patch", () => {
  const data = [[0, 1], [s(60), 2], [s(120), 3]];
  const hook = {
    ...Gaps,
    _isArrayPlot: () => false,
    _gapsOn: true,
    _gapSets: [[]],
    _gapLive: [],
    _gapFallback: { 0: 2000 },
    _rangeButtons: null,
    _resolution: null,
    _detail: null,
    _seriesData: { 0: data },
    _seriesMap: null,
    _symbols: ["circle"],
    _lone: () => false,
    _dataPatchOf: (d) => ({ data: d, showSymbol: false }),
  };
  const broken = hook._broken(0).data;
  const patch = hook._gapPatch(broken, 0);
  assert.equal(patch.sampling, "none");
  assert.equal(patch.showSymbol, true);
});

// -- reasons and regions -------------------------------------------------------

test("gaps keep their reason through joins, same starts and live events", () => {
  // joined: the earliest reason known
  assert.deepEqual(mergeGaps([[[s(100), s(500), "interrupted"]], [[s(450), s(700), "disconnected"]]]), [
    [s(100), s(700), "interrupted"],
  ]);
  assert.deepEqual(mergeGaps([[[s(100), s(500)]], [[s(450), s(700), "disconnected"]]]), [
    [s(100), s(700), "disconnected"],
  ]);
  // a gap that joins nothing keeps its own
  assert.deepEqual(mergeGaps([[[s(10), s(20), "stopped"], [s(30), s(40), "deactivated"]]]), [
    [s(10), s(20), "stopped"],
    [s(30), s(40), "deactivated"],
  ]);
  // an open gap with a reason, then a finite one without: the reason moves over
  assert.deepEqual(mergeGaps([[[s(100), null, "disconnected"]], [[s(100), s(250)]]]), [
    [s(100), s(250), "disconnected"],
  ]);
  // ... and a finite gap's own reason wins
  assert.deepEqual(mergeGaps([[[s(100), null, "disconnected"]], [[s(100), s(250), "stopped"]]]), [
    [s(100), s(250), "stopped"],
  ]);
  // live: the open event's reason, kept by the close
  assert.deepEqual(
    mergeGaps([], [
      { kind: "open", ms: s(100), at: 1, reason: "disconnected" },
      { kind: "close", ms: s(160), at: 2 },
    ]),
    [[s(100), s(160), "disconnected"]],
  );
  // no reason: two elements, as before
  assert.deepEqual(mergeGaps([[[s(1), s(2)]]]), [[s(1), s(2)]]);
});

test("breakLine reports every gap that qualifies, also two between the same readings", () => {
  const data = [[0, 1], [s(1000), 2]];
  const a = [s(100), s(220)];
  const b = [s(400), s(700)];
  const used = new Set();
  const { data: out } = breakLine(data, [a, b], { used });
  assert.equal(nulls(out).length, 1);
  assert.deepEqual([...used], [a, b]);

  // a 30 s gap at a 15-minute width is not shown, so not reported
  const coarse = new Set();
  breakLine(data, [[s(100), s(130)]], { widthAt: () => s(900), used: coarse });
  assert.equal(coarse.size, 0);
});

test("breakHeld reports only gaps it ended the line at", () => {
  const before = [s(10), s(50)];
  const after = [s(200), s(300)];
  const used = new Set();
  breakHeld([[s(100), 5]], [before, after], { used });
  // no setpoint in force before the first reading: nothing broke there
  assert.deepEqual([...used], [after]);
});

test("clipRowEnds reports a second qualifying gap inside a row's hold", () => {
  const first = [s(100), s(200)];
  const second = [s(400), s(700)];
  const used = new Set();
  const ends = clipRowEnds([0, s(1000)], [s(1000), s(1010)], [first, second], { used });
  assert.equal(ends[0], s(100));
  assert.deepEqual([...used], [first, second]);
});

test("gapAt finds the region under a time, at its edges and between regions", () => {
  const regions = [[s(10), s(20), "stopped"], [s(50), null]];
  assert.equal(gapAt(s(9), regions), null);
  assert.equal(gapAt(s(10), regions), regions[0]);
  assert.equal(gapAt(s(19), regions), regions[0]);
  assert.equal(gapAt(s(20), regions), null);
  assert.equal(gapAt(s(30), regions), null);
  assert.equal(gapAt(s(9999), regions), regions[1]);
  assert.equal(gapAt(0, []), null);
});

test("gapText says what, why and when", () => {
  const fmt = { time: (ms) => `t${ms / 1000}`, duration: (ms) => `${ms / 1000} s` };
  const reasons = {
    disconnected: "Node disconnected",
    deactivated: "Node deactivated",
    stopped: "Recording stopped",
    interrupted: "Recording interrupted",
  };
  for (const [reason, label] of Object.entries(reasons)) {
    assert.equal(gapText([s(20), s(28), reason], 0, fmt), `Not recorded\n${label}\nt20 → t28 · 8 s`);
  }
  // unknown: no reason line
  assert.equal(gapText([s(20), s(28)], 0, fmt), "Not recorded\nt20 → t28 · 8 s");
  // ongoing: the duration so far
  assert.equal(
    gapText([s(20), null, "disconnected"], s(200), fmt),
    "Not recorded\nNode disconnected\nsince t20 · 180 s, ongoing",
  );
});

test("regionMarks: an area per region, an open one to the edge, lines at the ends it has", () => {
  const { areas, lines } = regionMarks([[s(10), s(20)], [s(50), null, "disconnected"]]);
  assert.deepEqual(areas, [
    [{ xAxis: s(10) }, { xAxis: s(20) }],
    [{ xAxis: s(50) }, { xAxis: Infinity }],
  ]);
  assert.deepEqual(lines, [{ xAxis: s(10) }, { xAxis: s(20) }, { xAxis: s(50) }]);
});

// a fake number-plot hook: buffers by series index, which are setpoints
const plotHook = (gaps, seriesData, extra = {}) => ({
  ...Gaps,
  _isArrayPlot: () => false,
  _gapsOn: true,
  _gapSets: [gaps],
  _gapLive: [],
  _gapFallback: {},
  _rangeButtons: null,
  _resolution: null,
  _detail: null,
  _seriesData: seriesData,
  _targetIdx: new Set(),
  _heldTarget: (d) => [...d, [s(99999), d.length ? d[d.length - 1][1] : null]],
  _pointTs: (p) => p[0],
  ...extra,
});

// what _chartSeriesData does around the series data
const mark = (hook) => {
  hook._markBegin();
  Object.keys(hook._seriesData).forEach((idx) => hook._drawnData(idx));
  hook._markEnd();
  return hook._gapRegions();
};

test("the regions are the gaps a line or setpoint breaks at, not a too-short one", () => {
  const value = [...every(0, 100), ...every(400, 500), ...every(800, 900)];
  const target = [[0, 5], [s(850), 6]];
  const shown = [s(100), s(400), "disconnected"];
  const short = [s(600), s(601)];
  const held = [s(700), s(800)];
  // value: readings 1 s apart through the short and the held gap: no break;
  // the setpoint breaks at both qualifying gaps (it holds through them)
  const hook = plotHook([shown, short, held], { 0: value, 1: target }, { _targetIdx: new Set(["1"]) });
  const regions = mark(hook);
  assert.deepEqual(regions, [shown, held]);
});

test("gaps at the ends of the readings are marked: no reading after, or none before", () => {
  const value = every(100, 200);
  const closedAfter = [s(250), s(300)];
  const open = [s(400), null, "disconnected"];
  const before = [s(10), s(50)];
  const hook = plotHook([before, closedAfter, open], { 0: value });
  assert.deepEqual(mark(hook), [before, closedAfter, open]);
  // no readings at all: every gap
  assert.deepEqual(mark(plotHook([before], { 0: [] })), [before]);
});

test("an open gap stays marked with a reading stamped just after its start", () => {
  // the node's clock runs 2 s ahead of the server's g0
  const value = [...every(100, 200), [s(201), 7]];
  const open = [s(200), null];
  assert.deepEqual(mark(plotHook([open], { 0: value })), [open]);
});

test("a held setpoint's point at now doesn't unmark an open gap", () => {
  const open = [s(300), null];
  // the hold adds a point at s(99999); only recorded readings count
  const hook = plotHook([open], { 0: every(0, 100), 1: [[0, 5]] }, { _targetIdx: new Set(["1"]) });
  assert.deepEqual(mark(hook), [open]);
});

test("a module plot whose setpoint keeps its pre-window reading marks a gap past the left edge", () => {
  // live 10-minute window from s(600); the value's pre-outage readings trimmed,
  // the setpoint's reading in force kept from s(0)
  const gap = [s(60), s(700), "disconnected"];
  const hook = plotHook([gap], { 0: every(700, 1200), 1: [[0, 5]] }, { _targetIdx: new Set(["1"]) });
  assert.deepEqual(mark(hook), [gap]);
});

test("the regions are in time order when a later gap is found first", () => {
  const early = [s(100), s(300)];
  const late = [s(700), s(900)];
  // series 0 breaks only at the late gap, series 1 only at the early one
  const hook = plotHook([early, late], {
    0: [[0, 1], ...every(300, 600), ...every(900, 1000)],
    1: [...every(0, 100), [s(300), 1], [s(600), 1], [s(1000), 1]],
  });
  const regions = mark(hook);
  assert.deepEqual(regions, [early, late]);
});

test("fallback breaks of a session without spans mark nothing", () => {
  const data = [[0, 1], [s(600), 2], [s(1200), 3]];
  const hook = plotHook([], { 0: data }, { _gapFallback: { 0: 2000 } });
  assert.equal(nulls(hook._broken(0).data).length, 2);
  assert.deepEqual(mark(hook), []);
});

test("a heatmap marks the gaps its rows end at", () => {
  const cells = [];
  for (let t = 0; t <= 100; t += 10) cells.push([s(t), 0, 1], [s(t), 1, 2]);
  for (let t = 400; t <= 500; t += 10) cells.push([s(t), 0, 1], [s(t), 1, 2]);
  const gap = [s(105), s(400)];
  const short = [s(450), s(451)];
  const hook = arrayHook([gap, short], { _arrayMode: "heatmap", _seriesData: { 0: cells }, _pointTs: (p) => p[0] });
  hook._markBegin();
  hook._markEnd();
  assert.deepEqual(hook._gapRegions(), [gap]);
});
