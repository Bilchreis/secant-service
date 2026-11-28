# Tasks

## 1. Bindings

- [ ] 1.1 Add `SecantService.Systems` with the `Binding` struct, `bindings/1` and `bindings_for/2`, following design.md Decision 1:
  - read `custom_properties` `:systems` or `"systems"`, normalising keys with `to_string/1` and creating no atoms;
  - parse `Name:version`, with no version meaning 0; drop entries whose `system` is malformed and entries without a `modules` map;
  - skip roles whose value is not a module of the node (subsystems, missing modules);
  - sort each module's bindings by local system name.

  Verify `mix compile --warnings-as-errors`.
- [ ] 1.2 Add a `put_systems/2` helper to `test/support/node_fixtures.ex` that sets the node-level `systems` property of a raw description. Test `SecantService.Systems` in `test/secant_service/systems_test.exs` with every scenario of `specs/system-bindings/spec.md`:
  - a node's custom properties with atom keys (through `DescribeMessageTransformer.transform/1` on a fixture description);
  - the same node loaded back from the database (string keys), giving equal bindings.

  Verify the file passes.

## 2. Card behaviour and registry

- [ ] 2.1 Add the `SecantServiceWeb.SystemCard` behaviour (callbacks and their assigns as in design.md Decision 2, `plot_lines/1` optional). Its moduledoc says that a parameter shown by the body must be listed in `shown_parameters/1` to update live, and that the body must not assume the dashboard (it will be reused by system views). Verify `mix compile --warnings-as-errors`.
- [ ] 2.2 Add `SecantServiceWeb.SystemCards` with `match/2`, `matches/1` and `shown_parameters/1`, reading `Application.get_env(:secant_service, :system_cards, [])` at call time. Matching follows the order rules of `specs/system-module-cards/spec.md` ("Matching a card to a module"). Leave `:system_cards` unset in `config/` (no production cards). Verify `mix compile --warnings-as-errors`.
- [ ] 2.3 Add a test card in `test/support/system_cards/test_power_supply_card.ex`:
  - system `PowerSupply`, versions `[0]`, roles `current`/`voltage`, requiring and showing `control_active`;
  - a body with a `#sys-body-<module>` element that renders `value` and `control_active` through the helper components of 3.1;
  - `plot_lines/1` with `value`, `target` (setpoint) and `voltage_limit` (`y_axis: 1`).

  Add a second test card for another system, without `plot_lines/1`. Unit-test the registry in `test/secant_service_web/system_cards_test.exs`:
  - no config gives no matches;
  - a matching version and role;
  - an unlisted version or role, and a missing required parameter, fall back;
  - a module bound twice and two cards for one binding resolve in the documented order;
  - `shown_parameters/1` gives the declared pairs of matched modules only.

  Use `Application.put_env/3` with `on_exit` restore, `async: false`. Verify the file passes.

## 3. Custom cards on the dashboard

- [ ] 3.1 Add `SecantServiceWeb.SystemCards.Components` (`card_param`, `card_status`, `card_sparkline`, `card_command`), building the same component ids as the generic card (design.md Decision 3). Verify `mix compile --warnings-as-errors`.
- [ ] 3.2 Load the `daisyui` skill. In `ModuleGrid`:
  - move the chrome of `module_card/1` into a private `card_shell/1` with an inner block, and keep the generic card's rendered markup unchanged;
  - add `system_card/1`: the shell, a `PowerSupply:0 · current` badge in the header (`data-system-card` attribute on the article) and the card's `body/1` in place of the generic body;
  - in `module_grid/1`, compute `SystemCards.matches/1` once and use `system_card/1` for matched modules among the non-acquisition modules only.

  Update the `DashboardComponents` moduledoc, which says cards may assume nothing beyond SECoP's standard parameters, to explain the system-card exception. Verify that the existing dashboard and acquisition-card LiveView tests pass unchanged.
- [ ] 3.3 In `ModuleDetail`, list the module's bindings below the header (`#system-membership`, one entry per binding with its role, local system name and `Name:version`), in both modes. Verify with 3.4.
- [ ] 3.4 Add `test/secant_service_web/live/system_card_test.exs` with a fixture node that declares a `PowerSupply:0` system (`put_systems/2`) and registers the test cards. Cover the scenarios of `specs/system-module-cards/spec.md`, asserting on element ids:
  - the matched module renders `#card-<name>[data-system-card] #sys-body-<name>`;
  - no cards configured, an unlisted version or role, and a missing required parameter give the generic card;
  - an acquisition channel bound in the system stays inside `#acq-<ctrl>`;
  - selecting the custom card gives it the selection border, and pausing the node gives it the stale look;
  - a new description that adds the system switches the module to the custom card;
  - the panel shows `#system-membership` for a bound module and not for an unbound one.

  Verify the file passes.

## 4. Live values of card parameters

- [ ] 4.1 In `DashboardLive`, add the uuid-keyed `card_params` cache and route the declared `{module, param}` pairs to `module_dash:<node>:<module>:<param>` in `update_components`, skipping those `update_cards/4` already sends (design.md Decision 4). In `system_card_test.exs`, add tests that:
  - a pushed `control_active` value reaches the custom card's display;
  - a parameter not declared by any card sends nothing to a `module_dash:` id.

  Also assert that the card shows the node's current `control_active` on first render. Verify the file passes.

## 5. Custom module plot

- [ ] 5.1 In `SecantService.PlotDB`, add the optional line-definition argument to `lines`, `param_list`, `plottable?` and `init` (nil keeps today's behaviour). Give every line a `y_axis` (0 for interface-class lines), and fall back to the interface-class lines when the first definition does not survive `find_param` + `History.thinnable?`. In `TimePlot`/`Scalar.timeseries_option`, build the two-axis option when a line has `y_axis: 1` (left: primary unit, right: first axis-1 line's unit, `yAxisIndex: 1` on its series, wider `grid.right`), and leave the option unchanged otherwise. Test in `test/secant_service/plot_db_test.exs`:
  - nil definitions give today's lines;
  - custom order, setpoint (`_held`, no band) and hidden (`legend.selected`) lines;
  - a missing optional parameter is left out;
  - a string primary falls back;
  - an enum primary ignores the other lines;
  - the two-axis option's axes and `yAxisIndex`.

  Verify the file passes.
- [ ] 5.2 In `HistoryDB`, accept an optional `line_defs` assign, store it on mount and pass it at every `PlotDB` call site: the first load, `set-display-mode` reloads, the range, window and overview fetches, and the live `param_list` filter. Verify that the existing `HistoryDB`/plot tests pass unchanged.
- [ ] 5.3 In `ModuleDetail`, pass the matched card's `plot_lines/1` as `line_defs` to the module plot only (never to a parameter plot), and gate the plot on `PlotDB.plottable?(module, line_defs)`. In `system_card_test.exs`, add tests that:
  - the live module plot of the matched module draws the three test-card lines;
  - a pushed `voltage_limit` reading is sent as an `extend-chart-<id>` update;
  - a parameter plot opened from a row stays generic.

  In `test/secant_service_web/live/node_browser_live_test.exs`, add a test that the stored session's module plot draws the same lines. Verify both files pass.

## 6. Integration

- [ ] 6.1 Load the `run-app` skill. `test/support` is not compiled in dev, so ask the user before a temporary, uncommitted setup:
  - a copy of the test card under `lib/` and a `:system_cards` entry in `config/dev.exs` (the user restarts the dev server; never start or stop it yourself);
  - a node that declares a `PowerSupply:0` system, such as a frappy sim config with a `systems` property.

  Then in headless Chrome check:
  - the custom card;
  - the two-axis module plot extending live, zooming in the data browser, and breaking at a recording gap (pause and resume the node).

  Report what was seen. Afterwards remove the temporary card and config, and verify that `git status` shows neither.
- [ ] 6.2 Run `mix precommit` and fix everything it reports. Verify it exits cleanly.
