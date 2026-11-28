# Tasks

## 1. Bindings

- [x] 1.1 Add `SecantService.Systems` (`bindings/1`, `bindings_for/2`, `parse_reference/1`), with the `Binding` struct (including `parents`) in its own file, `lib/secant_service/systems/binding.ex`. Follow design.md Decision 1:
  - make it total: a non-map `systems`, non-map entries, and role keys or values that are neither strings nor atoms are skipped, never raised on;
  - read `custom_properties` `"systems"` or `:systems`, normalising atom keys and creating no atoms;
  - parse references (no `:` is version 0; the suffix must match `~r/\A\d+\z/` and parse to `{n, ""}`; the name must be non-empty), and drop malformed entries and entries without a `modules` map;
  - bind module names (module names win over local names); record subsystem containment and resolve parents outwards with a visited set, following the containing entry first by local system name;
  - sort each module's bindings by local system name.

  Verify `mix compile --warnings-as-errors`.
- [x] 1.2 Add a `put_systems/2` helper to `test/support/node_fixtures.ex` that sets the node-level `systems` property of a raw description. In `test/secant_service/systems_test.exs`, test every scenario of `specs/system-bindings/spec.md`, including the malformed shapes and `"PowerSupply:1\n"`:
  - on custom properties with string keys (a node stored through `NodeManager`/`upsert_sec_node` and loaded back, as the dashboard and data browser get it);
  - on the atom-key output of `DescribeMessageTransformer.transform/1`, giving equal bindings.

  Verify the file passes.

## 2. Behaviours, plot specs, registry, card helpers, test systems

- [x] 2.1 Add the `SecantServiceWeb.SystemDefinition` (`system/0`, `versions/0`, `roles/1`) and `SecantServiceWeb.SystemRole` (`required_parameters/0`, `card/0`, `plot/0`, all required, nil for none) behaviours, as in design.md Decision 2. The moduledocs say:
  - a shown parameter must be listed in `shown_parameters` to update live, and a body shows each parameter at most once;
  - bodies use the `location` assign and must not assume the dashboard (system views will reuse them).

  Add the `LinesPlot`, `ArrayPlot`, `Trace` and `LabelSource` structs (Decision 5), each in its own file under `lib/secant_service/plot_db/`, with typespecs. Verify `mix compile --warnings-as-errors`.
- [x] 2.2 Add `SecantServiceWeb.Systems` with `matches/1` and `shown_parameters/1`, finding the system modules under its namespace (`discovered/0`) unless `:systems` lists them, without those in `:disabled_systems`, read at call time, and following the order rules of `specs/system-module-cards/spec.md`. Document the settings in `config/config.exs`. Verify `mix compile --warnings-as-errors`.
- [x] 2.3 Add `SecantServiceWeb.Systems.Components` (`card_param`, `card_status`, `card_sparkline`, `card_command`), building ids from `node`, `module` and `location` as design.md Decision 3 describes. Verify `mix compile --warnings-as-errors`.
- [x] 2.4 Add test systems in `test/support/systems/`, each module in its own file:
  - `TestPowerSupply` (system `PowerSupply`, versions `[0]`):
    - role `current`: requires and shows `control_active`; a card body with a `#sys-body-<module>` element rendering `value` and `control_active` through the 2.3 helpers; a lines plot of `value`, `target` (setpoint), `voltage_limit` (axis 1) and `power_limit` (hidden);
    - role `voltage`: card only, no plot.
  - `TestMfcGroup`: one role, lines plot only. It draws `value.composition` per element, labelled from `value.gas_list`, and `value.total_flow` on axis 1.
  - `TestMassSpec`: one role, an array plot (of `value`) labelled from `_mass` with template `m/z {}` and axis name `m/z`.
  - `TestMassTrend`: one role, a lines plot of the `value` elements picked by `_mass` 28 and 44, labelled from `_mass` with template `m/z {}`.

  Unit-test the registry in `test/secant_service_web/systems_test.exs`:
  - discovery finds the probe under the namespace and nothing else; a disabled definition is left out; an explicit list replaces discovery;
  - no systems gives no matches;
  - matching version and role;
  - an unhandled version, a role without a module, and a missing required parameter fall back;
  - a module bound twice resolves in binding order, and two system modules for one name in config order;
  - a module inside a subsystem matches its inner system;
  - `shown_parameters/1` gives only the declared pairs of matched roles with a card.

  Use `Application.put_env/3` with `on_exit` restore, `async: false`. Verify the file passes.

## 3. Custom cards on the dashboard

- [x] 3.1 In `DashboardLive`, add the uuid-keyed `systems` assign (`{uuid, bindings, matches, shown}`) through an `assign_systems/1` helper piped after each `Model.to_socket/2` call (not inside `SecantService.Model`). Pass `matches` to `ModuleGrid`, and `matches` and `bindings` to `ModuleDetail`. In the node browser, compute `bindings` and `matches` once per loaded session and pass them to `ModuleDetail`. Verify that the existing dashboard and node browser LiveView tests pass unchanged.
- [x] 3.2 Load the `daisyui` skill. In `ModuleGrid`:
  - move the chrome of `module_card/1` into a private `card_shell/1` with `:badge`, `:inner_block` and `:actions` slots, keeping the generic card's rendered markup unchanged;
  - add `system_card/1`: the shell (keeping its `data-stale` and `data-status` attributes), the `#card-<name>-system` badge, `data-system`/`data-role` on the article, the role's card body with assigns including `location: "module_dash"`, and a params button counting all of the module's commands;
  - use it for matched modules whose role gives a card, among the non-acquisition modules only.

  Update the `DashboardComponents` moduledoc, which says cards may assume nothing beyond SECoP's standard parameters, to explain the system-card exception. Verify that the existing dashboard and acquisition-card LiveView tests pass unchanged.
- [x] 3.3 In `ModuleDetail`, list the module's bindings below the header (`#system-membership`, one entry per binding with role, local system name, `Name:version` and its parents), in both modes. Verify with 3.4.
- [x] 3.4 Add `test/secant_service_web/live/system_card_test.exs`, with a fixture node declaring `PowerSupply:0` and `VectorMagnet:0` systems (`put_systems/2`) and the test systems registered. Cover the scenarios of `specs/system-module-cards/spec.md`, asserting on element ids and data attributes:
  - the matched module renders `#card-<name>[data-system="PowerSupply:0"][data-role="current"] #sys-body-<name>`;
  - no systems configured, an unhandled version, a role without a module, and a missing required parameter give the generic card;
  - a role with a plot and no card gives the generic card with no badge;
  - a module inside the `VectorMagnet` subsystem gets the `PowerSupply` card;
  - an acquisition channel bound in the system stays inside `#acq-<ctrl>`;
  - selecting the custom card gives it the selection border, and pausing the node gives it the stale look;
  - a new description that adds the system switches the module to the custom card;
  - a node with a malformed `systems` property renders every module with the generic card;
  - `#system-membership` lists role, system and parents for a bound module, and is absent for an unbound one, on the dashboard and in the node browser.

  Verify the file passes.

## 4. Live values of card parameters

- [x] 4.1 In `DashboardLive`, add the pure `card_route/3` and use it in `update_components` (now taking `shown` as a sixth argument) to route the shown pairs to `module_dash:<node>:<module>:<param>`, skipping only `value` and `target`, which `update_cards/4` already sends there (design.md Decision 4). Test:
  - `card_route/3` in a unit test (a shown `control_active` and a shown `goal` are routed; `value` and `target` are not routed twice; an undeclared parameter is not routed);
  - in `system_card_test.exs`, that a pushed `control_active` value reaches the custom card's display, and that the card shows the node's current `control_active` on first render.

  Verify both pass.

## 5. Custom module plot

- [x] 5.1 Add the total functions of design.md Decision 5:
  - `Trace.extract/3`: string-then-existing-atom keys, list indices; non-numbers give nil;
  - `LabelSource.text/2`: strings as they are, whole numbers without a fraction, other numbers in short form, the `{}` template, nil otherwise;
  - `PlotDB.drawable?/2`: declared types only, `Scalar.supported_type?/1` numbers (no enums), `History.thinnable?/1`, struct-only paths, arrays of at most 100 elements; `is_map` checked at every step, so malformed datainfo gives false; no database access;
  - `Traces.latest_value/1`: the latest stored value of any type (`SecNodes.latest_reading` + `Storage.raw_value`);
  - `Traces.resolve/2`, in design.md Decision 5's order:
    1. drop undrawable traces;
    2. pre-check undeclared arrays with `latest_value` before any window fetch;
    3. read the other latest values once per parameter;
    4. expand `:each` to `min(declared || latest length, 100)`;
    5. resolve `{:match, …}` with `==` to a concrete `{:index, k}`;
    6. give stable names (`value`, `value.composition[2]`, `value[27]`);
    7. dedupe, then cut to 16;
    8. return `:no_traces` when empty.

  Unit-test in `test/secant_service/plot_db/traces_test.exs`:
  - `extract/3` on atom- and string-key structs, short arrays, nil and error values;
  - `text/2` on `28.0`, `28.5`, a string, a map, nil and a template;
  - `drawable?/2` on a missing parameter, an enum, a path to a string, an array-of-struct path, a 350 000-element `maxlen`, and malformed datainfo (a list where a map belongs), and that it makes no Repo query;
  - `traces/2` on:
    - `:each` with and without a declared length;
    - an undeclared array whose latest reading has 200 elements (dropped before any window query);
    - a match found and not found (28.0 against 28, and 28 against 28.0), resolved to `{:index, k}`;
    - duplicates (removed before the cut);
    - stable names;
    - the 16 cap.

  Test `latest_value/1` returning a struct value.

  Verify the file passes.
- [x] 5.2 In `TimePlot`/`Scalar`, add `build_lines/3` as design.md Decision 5 describes:
  - one window fetch per distinct parameter (the held fetch for setpoint parameters), with traces extracted;
  - `_label` on the series, and fallbacks;
  - readings with no number at a trace's path dropped, not sent as `[ts, nil]`;
  - setpoint (`_held`) and hidden (`legend.selected`) traces;
  - `Gaps.put/3` (its fallback already takes only a number `value`, since #185);
  - the two-axis option, with fallback units read along each trace's path.

  Give the plot `lines` (keyed by series name), `resolved` (one fetch line per distinct parameter) and `traces`. Add a `trace_updates/3` clause for `traces` before the `lines` clause, and call it once per distinct parameter from `window_reply/2`. Make `PlotDB.init/3` fall back to `init/2` on `:no_traces`. Make `Scalar.series_updates/3` return `[]` for an unknown series. Test in `test/secant_service/plot_db/custom_plot_test.exs` with stored readings:
  - cost by distinct parameter: the Repo statements of four element traces of one parameter equal those of one trace of it. No helper exists, so count them with an inline `:telemetry.attach` on the Repo's query event;
  - the custom plot carries `_gaps` and a gap reply, and a span-less session's estimate applies only to the whole `value` trace, not to `value.composition[2]` or `value[27]`;
  - a generic struct plot's live update still lands on the right series after the `series_updates/3` change;
  - an error reading gives no point and no break;
  - the MFC group gives four gas-labelled composition traces plus `total_flow` with `yAxisIndex: 1` and the axis labels; equal gas names still give four series;
  - the mass trend picks the elements of masses 28 and 44 and labels them `m/z 28` and `m/z 44`, with `_mass` read by one latest-reading query;
  - a missing label falls back;
  - live `trace_updates/3` fans out by stable name, and a gas-list change keeps the labels;
  - a whole number trace gets a band and an element trace doesn't.

  Verify the file passes.
- [x] 5.3 In `PlotDB.init` with an `ArrayPlot`, follow today's array path for `value` and read the label source once with `latest_value`:
  - a heatmap gets `_indexLabels` for the first `min(source length, 100)` entries;
  - a latest-reading plot gets `_indexLabels` only when the source has at most 4000 entries;
  - the axis name goes into the index axis's `name` on the server (`ArrayHeatmap.index_axis/1`, `ArrayLatest.option/3`).

  Make `HistoryDB.rebuild_as_latest/3` pass the spec, so the rebuild reads the label source again. Test in `test/secant_service/plot_db/custom_plot_test.exs`:
  - the mass spec heatmap gets `m/z 1`, `m/z 2`, … and the axis name;
  - 90 `_mass` entries for 100 elements leave indexes 90–99 unlabelled;
  - a heatmap loaded at 3 elements with a 10-entry source carries 10 labels;
  - a latest-reading plot with a 3000-entry source carries 3000 labels, and with a 10 000-entry source none;
  - a rebuild reads the label source again.

  Verify the file passes.
- [x] 5.4 In the chart hook, show labels as design.md Decision 5 describes:
  - move `escHtml` into a new pure `assets/js/charts/labels.mjs` (re-exported from `common.js`), with the label helpers;
  - the legend formatter gets the raw `_label || name` (canvas);
  - a number-plot axis-tooltip formatter, installed only when some series has `_label`, escapes;
  - `bands.js` `_envelopeTooltip` uses the escaped label;
  - with `_indexLabels`:
    - the heatmap index-axis formatter (canvas, raw) and hover readout (`textContent`, raw);
    - in lines mode, `_linesTooltip` looking labels up by element index (escaped), keeping the `[i]` series names;
    - `ArrayLatest`'s index-axis formatter (canvas, raw) and its tooltip (escaped).

  Add `assets/js/charts/labels.test.mjs`: a `<b>N2</b>` label is escaped for tooltips and raw for canvas and `textContent`, and an index without a label shows its number. Add it to the `node --test` step in `.github/workflows/ci.yml`. Verify `node --test assets/js/charts/gaps.test.mjs assets/js/charts/labels.test.mjs` passes.
- [x] 5.5 In `HistoryDB`, accept an optional `plot_spec` assign. Check `PlotDB.drawable?/2` on mount when one is given, and pass it to `init` on mount, on reloads and on `rebuild_as_latest/3`. When a load returns `%{plottable: false}` and `tabular?/1` holds, switch to the table instead of leaving an empty chart. When the loaded plot carries `traces`, make the range, window and overview handlers and the live filter read `plot.resolved`, fetching once per distinct `param.id` and fanning out. Other plots keep today's code. Verify that the existing `HistoryDB`, plot and LiveView tests pass unchanged.
- [x] 5.6 In `ModuleDetail`, pass the matched role's `plot()` as `plot_spec` to the module plot only (never to a parameter plot), and only when the module has a `value`, keeping today's `@plot_parameter || @has_value` gate. In `system_card_test.exs`, test that:
  - the live module plot of the matched `current` module draws the four test traces, with `power_limit` deselected in `legend.selected`;
  - a pushed `voltage_limit` reading is sent as an `extend-chart-<id>` update;
  - the `voltage` role (card, no plot) gets the generic module plot;
  - a parameter plot opened from a row stays generic;
  - a module with a string `value` and no match still shows the table;
  - a role whose only trace picks a mass not in `_mass`, on a module with a string `value`, shows the table;
  - the mass spec module's plot carries `_indexLabels`.

  In `test/secant_service_web/live/node_browser_live_test.exs`, test that the stored session's custom lines plot draws the same traces, and drive `fetch-chart-window`, `fetch-chart-overview` and `fetch-chart-range` on it with `render_hook` (as the existing tests there do), asserting the replies carry the custom traces. Verify both files pass.

## 6. Integration

- [x] 6.1 Load the `run-app` skill. `test/support` is not compiled in dev, so ask the user before a temporary, uncommitted setup:
  - copies of the test systems under `lib/` and a `:systems` entry in `config/dev.exs` (the user restarts the dev server; never start or stop it yourself);
  - nodes that declare the systems: e.g. a frappy sim config with a `systems` property for a power supply and an MFC group, and the ROCK-IT `gas_analysis` sim's `mass_spec` bound to the mass spec test systems.

  In headless Chrome, check:
  - the custom card;
  - the two-axis lines plot extending live, zooming in the data browser, and breaking at a recording gap (pause and resume the node);
  - gas-name labels in the legend, the live tooltip and the banded historical tooltip;
  - the mass spec heatmap's `m/z` axis, its lines mode and the mass-picked traces.

  Report what was seen. Afterwards remove the temporary systems and config, and verify that `git status` shows neither.
- [x] 6.2 Run `mix precommit` and fix everything it reports. Verify it exits cleanly.
