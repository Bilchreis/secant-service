# Tasks

## 1. Bindings

- [ ] 1.1 Add `SecantService.Systems` with the `Binding` struct (including `parents`), `bindings/1`, `bindings_for/2` and `parse_reference/1`, following design.md Decision 1:
  - read `custom_properties` `"systems"` or `:systems`, normalising keys with `to_string/1` and creating no atoms;
  - parse references (no `:` is version 0, digits-only suffix, non-empty name) and drop malformed entries and entries without a `modules` map;
  - bind module names (module names win over local names); record subsystem containment and resolve parents outwards with a visited set, following the containing entry first by local name;
  - sort each module's bindings by local system name.

  Verify `mix compile --warnings-as-errors`.
- [ ] 1.2 Add a `put_systems/2` helper to `test/support/node_fixtures.ex` that sets the node-level `systems` property of a raw description. In `test/secant_service/systems_test.exs`, test every scenario of `specs/system-bindings/spec.md`:
  - on custom properties with string keys (a node stored through `NodeManager`/`upsert_sec_node` and loaded back, as the dashboard and data browser get it);
  - on the atom-key output of `DescribeMessageTransformer.transform/1`, giving equal bindings.

  Verify the file passes.

## 2. System and role behaviours, registry

- [ ] 2.1 Add the `SecantServiceWeb.SystemDefinition` (`system/0`, `versions/0`, `roles/1`) and `SecantServiceWeb.SystemRole` (`required_parameters/0`, `card/0`, `plot/0`, all required, nil for none) behaviours, as in design.md Decision 2. The moduledocs say:
  - a shown parameter must be listed in `shown_parameters` to update live, and a body shows each parameter at most once;
  - bodies use the `location` assign and must not assume the dashboard (system views will reuse them).

  Add `SecantService.PlotDB.PlotSpec` and `Trace` structs (Decision 5) with typespecs. Verify `mix compile --warnings-as-errors`.
- [ ] 2.2 Add `SecantServiceWeb.Systems` with `matches/1` and `shown_parameters/1`, reading `Application.get_env(:secant_service, :systems, [])` at call time and following the order rules of `specs/system-module-cards/spec.md`. Document `config :secant_service, :systems, []` in `config/config.exs`. Verify `mix compile --warnings-as-errors`.
- [ ] 2.3 Add test systems in `test/support/systems/`:
  - `TestPowerSupply` (system `PowerSupply`, versions `[0]`), with role modules:
    - `current`: requires and shows `control_active`; its card body has a `#sys-body-<module>` element rendering `value` and `control_active` through the 3.1 helpers; plot traces `value`, `target` (setpoint) and `voltage_limit` (axis 1);
    - `voltage`: card only, no plot;
  - `TestMfcGroup`: one role, plot only. Its traces are `value` → `composition` per element, labelled `{:path, ["gas_list"]}`, and `value` → `total_flow` on axis 1.

  Unit-test the registry in `test/secant_service_web/systems_test.exs`:
  - no config gives no matches;
  - matching version and role;
  - an unhandled version, a role without a module, and a missing required parameter fall back;
  - a module bound twice resolves in binding order, and two system modules for one name in config order;
  - a module inside a subsystem matches its inner system;
  - `shown_parameters/1` gives only the declared pairs of matched roles with a card.

  Use `Application.put_env/3` with `on_exit` restore, `async: false`. Verify the file passes.

## 3. Custom cards on the dashboard

- [ ] 3.1 Add `SecantServiceWeb.Systems.Components` (`card_param`, `card_status`, `card_sparkline`, `card_command`), building ids from `node`, `module` and `location` as design.md Decision 3 describes. Verify `mix compile --warnings-as-errors`.
- [ ] 3.2 In `DashboardLive`, add the uuid-keyed `systems` assign (`{uuid, matches, shown}`) and pass `matches` to `ModuleGrid` and `ModuleDetail`. In the node browser, compute `matches` once per loaded session and pass it to `ModuleDetail`. Verify that the existing dashboard and node browser LiveView tests pass unchanged.
- [ ] 3.3 Load the `daisyui` skill. In `ModuleGrid`:
  - move the chrome of `module_card/1` into a private `card_shell/1` with `:badge`, `:inner_block` and `:actions` slots, keeping the generic card's rendered markup unchanged;
  - add `system_card/1`: the shell, the `#card-<name>-system` badge, `data-system`/`data-role` on the article, and the role's card body with assigns including `location: "module_dash"`;
  - use it for matched modules whose role gives a card, among the non-acquisition modules only.

  Update the `DashboardComponents` moduledoc, which says cards may assume nothing beyond SECoP's standard parameters, to explain the system-card exception. Verify that the existing dashboard and acquisition-card LiveView tests pass unchanged.
- [ ] 3.4 In `ModuleDetail`, list the module's bindings below the header (`#system-membership`, one entry per binding with role, local system name, `Name:version` and its parents), in both modes. Verify with 3.5.
- [ ] 3.5 Add `test/secant_service_web/live/system_card_test.exs`, with a fixture node declaring `PowerSupply:0` and `VectorMagnet:0` systems (`put_systems/2`) and the test systems registered. Cover the scenarios of `specs/system-module-cards/spec.md`, asserting on element ids and data attributes:
  - the matched module renders `#card-<name>[data-system="PowerSupply:0"][data-role="current"] #sys-body-<name>`;
  - no systems configured, an unhandled version, a role without a module, and a missing required parameter give the generic card;
  - a role with a plot and no card gives the generic card with no badge;
  - a module inside the `VectorMagnet` subsystem gets the `PowerSupply` card;
  - an acquisition channel bound in the system stays inside `#acq-<ctrl>`;
  - selecting the custom card gives it the selection border, and pausing the node gives it the stale look;
  - a new description that adds the system switches the module to the custom card;
  - `#system-membership` lists role, system and parents for a bound module, and is absent for an unbound one, on the dashboard and in the node browser.

  Verify the file passes.

## 4. Live values of card parameters

- [ ] 4.1 In `DashboardLive`, add the pure `card_route/3` and use it in `update_components` to route the shown pairs to `module_dash:<node>:<module>:<param>`, skipping those `update_cards/4` already sends (design.md Decision 4). Test:
  - `card_route/3` in a unit test (a shown extra parameter is routed; `value` is not routed twice; an undeclared parameter is not routed);
  - in `system_card_test.exs`, that a pushed `control_active` value reaches the custom card's display, and that the card shows the node's current `control_active` on first render.

  Verify both pass.

## 5. Custom module plot

- [ ] 5.1 Add `Trace.extract/2` (never raises; string-then-existing-atom keys, array indices, non-numbers give nil) and `PlotDB.traces/2` (find the parameter, check the declared type gives a number at the path, expand `each` from `Channels.declared_length/1` or the latest reading, cut to 16, stable series names, fall back to the generic lines when empty). Unit-test in `test/secant_service/plot_db/traces_test.exs`:
  - `extract/2` on atom- and string-key structs, short arrays, nil and error values;
  - traces: a missing parameter, a path to a string, an all-undrawable spec, a 200-element `maxlen` cut to 16, and stable names (`value`, `value.composition[2]`).

  Verify the file passes.
- [ ] 5.2 In `TimePlot`/`Scalar`, add `build_custom/3`:
  - one window fetch per distinct parameter (the held fetch for setpoint parameters), with traces extracted from it;
  - labels from the latest reading (`_label` on the series), fallback labels;
  - setpoint (`_held`) and hidden (`legend.selected`) traces;
  - bands only for whole-parameter, non-setpoint traces;
  - `Gaps.put/3`;
  - the two-axis option.

  Give the plot `traces`, and make `trace_updates/3` fan readings out to their traces. Make `Scalar.series_updates/3` return `[]` for an unknown series instead of series 0. Test in `test/secant_service/plot_db_test.exs` with stored readings:
  - query count: one window per parameter, as design.md states;
  - the MFC group gives four labelled composition traces plus `total_flow` on axis 1, with `yAxisIndex: 1` and the axis labels;
  - a missing label falls back;
  - live `trace_updates/3` fans out by stable name, and a gas-list change keeps the labels;
  - the band and gap rules.

  Verify the file passes.
- [ ] 5.3 In `echarts_chart.js`, show `_label || name` in the legend and tooltip. Verify with 6.1, and with a `node --test` case alongside `assets/js/charts/gaps.test.mjs` if the formatter is a pure function.
- [ ] 5.4 In `HistoryDB`, accept an optional `plot_spec` assign. Use it for `plottable?` and `init` on mount and reloads. When the loaded plot carries `traces`, make the range, window and overview handlers fetch once per distinct parameter and fan out, and make the live filter read the plot's traces. Plots without `traces` keep today's code. Verify that the existing `HistoryDB`, plot and LiveView tests pass unchanged.
- [ ] 5.5 In `ModuleDetail`, pass the matched role's `plot()` as `plot_spec` to the module plot only (never to a parameter plot), and gate it on `@plot_parameter || @has_value || custom plot drawable`. In `system_card_test.exs`, test that:
  - the live module plot of the matched `current` module draws the three test traces;
  - a pushed `voltage_limit` reading is sent as an `extend-chart-<id>` update;
  - a parameter plot opened from a row stays generic;
  - a module with a string `value` and no match still shows the table.

  In `test/secant_service_web/live/node_browser_live_test.exs`, test that the stored session's module plot draws the same traces. Verify both files pass.

## 6. Integration

- [ ] 6.1 Load the `run-app` skill. `test/support` is not compiled in dev, so ask the user before a temporary, uncommitted setup:
  - copies of the test systems under `lib/` and a `:systems` entry in `config/dev.exs` (the user restarts the dev server; never start or stop it yourself);
  - a node that declares a `PowerSupply:0` system and an MFC-group-like module, e.g. a frappy sim config with a `systems` property.

  In headless Chrome, check:
  - the custom card;
  - the two-axis module plot extending live, zooming in the data browser, and breaking at a recording gap (pause and resume the node);
  - the gas-name labels in the legend and tooltip.

  Report what was seen. Afterwards remove the temporary systems and config, and verify that `git status` shows neither.
- [ ] 6.2 Run `mix precommit` and fix everything it reports. Verify it exits cleanly.
