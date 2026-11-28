# Design

## Context

See proposal.md (Why). The relevant state of the code:

**Where `systems` lands.** `DescribeMessageTransformer.extract_custom_properties/1` drops only the standard node properties (`description`, `equipment_id`, `firmware`, `implementor`, `timeout`). A node's `systems` property therefore ends up in `SecNode.custom_properties`: with atom keys when the dashboard gets the node from a fresh description, with string keys when it is loaded from the database (the data browser). `SecantService.Acquisition.channel_map/1` already reads a property like this, accepting both key types. No code reads `systems` yet.

**Cards.** `ModuleGrid.module_grid/1` drops the channels that a controller claims (`Acquisition.channel_names/1`), groups the rest (`group_modules/1`), and splits each group into controllers (acquisition cards) and others (`module_card/1`). `module_card/1` owns the chrome (the `card-<name>` id, selection border, `card_tint`/`card_edge`, dashed look while stale, header and the params button) and the body (`ModuleIndicator`, `value`/`target` `ParameterValueDisplay`s, `Sparkline`, `stop`/`go` `CommandDisplay`s).

**Live values on cards.** `DashboardLive.handle_info({:value_updates, …})` calls `update_cards/4`, which routes only:
- `status` → `module_indicator(_mod):<node>:<module>`;
- `value`, `target` → `module_dash:<node>:<module>:<param>`;
- `goal`, `goal_enable` → `AcquisitionGoal`.

Any other parameter reaches only the inspector of the selected module. `ParameterValueDisplay` reads its first value from `NodeTable` on mount, so a newly rendered display starts with the current value whatever the routing.

**Module plot.** `PlotDB.lines(%Module{})` picks the lines from `@class_lines` by the highest interface class, as `%{param:, series:, setpoint?:, hidden?:}`. `HistoryDB` takes a `secop_obj` and calls `PlotDB.lines/1`, `param_list/1`, `plottable?/1` and `init/2` on it:
- on the first load and on reloads (`set-display-mode`);
- in `fetch-chart-range`, `fetch-chart-window` and `fetch-chart-overview`;
- to filter live readings (`param_list/1`).

`TimePlot.build/2` dispatches on the first line's dtype. Only `Scalar` draws more than a value and one setpoint. Setpoint behaviour downstream keys off flags, not names:
- `held: line.setpoint?` sets `_held`, which drives the hold and the gap rules in `setpoints.js`/`gaps.mjs`;
- `Bands.eligible?/1` checks `setpoint?`;
- only the series named `target` gets the dashed `_target` style.

`Scalar.timeseries_option/4` builds a single `yAxis`. The chart hook already accepts a `yAxis` list (`echarts_chart.js` maps it), and `bands.js` copies a parent's `yAxisIndex` to its band.

**Panel.** `ModuleDetail.module_detail/1` is shared by the dashboard inspector (`:live`) and the node browser (`:historical`). It renders `HistoryDB` for the module when it has a `value`. The plot's component id (`plot:<uuid>:…:<module>:module`) includes the session uuid, so a new description mounts a fresh `HistoryDB`.

## Goals / Non-Goals

**Goals:**
- One place that reads bindings, shared by the cards, the panel and, later, the system views.
- The plotting layer (`SecantService.PlotDB`) stays independent of the web layer. It gets a custom line set as plain data, never by looking up a card.
- A module with no matching card renders and plots exactly as today, with no extra work per render beyond the binding lookup.

**Non-Goals:**
- A plug-in or hot-loading mechanism. Cards are compiled modules named in config.
- Isolating a crashing card body from the rest of the dashboard (see Risks).
- Changing `PlotCache`, `NodeValues` or what gets recorded. `PlotCache` already buffers every parameter of the description.

## Decisions

### 1. `SecantService.Systems`: bindings as a pure function of the node

A new module with a `Binding` struct (`local_name`, `system`, `version`, `role`, `description`, `module`). It has two functions:
- `bindings(node)` returns `%{module_name => [Binding]}`;
- `bindings_for(node, module_name)` returns that module's list.

It reads `custom_properties[:systems] || custom_properties["systems"]` and normalises keys with `to_string/1`, like `Acquisition`. It never creates atoms. Reference parsing:
- split once on the last `:`;
- the version must parse with `Integer.parse/1` to a whole non-negative integer;
- no `:` means version 0;
- anything else drops the entry.

A role whose value is not one of the node's module names is skipped, which covers subsystems and missing modules. Bindings per module are sorted by `local_name`.

*Alternatives:*
- Storing bindings as Ash attributes or a table: rejected. They are derivable from the stored description, need no query, and a migration would buy nothing.
- Resolving subsystems recursively: deferred to the system views, which need the tree. Cards bind one module to one role.

### 2. A card is a behaviour module; the registry is config

`SecantServiceWeb.SystemCard` (behaviour) declares:
- `system() :: String.t()`, `versions() :: [non_neg_integer()]`, `roles() :: [String.t()]`;
- `required_parameters(role) :: [String.t()]`;
- `shown_parameters(role) :: [String.t()]`: the parameters whose live values the body displays;
- `body(assigns)`: a function component. Its assigns are `module`, `node`, `node_id_str`, `binding`, `role`, `node_state` and `status`;
- optional `plot_lines(role) :: [line_def] | nil`, checked with `function_exported?/3`.

`SecantServiceWeb.SystemCards` (registry) reads `Application.get_env(:secant_service, :system_cards, [])` at call time and offers:
- `match(node, module)`: the first binding in binding order, then the first card in config order, whose `system` equals the binding's, whose `versions` include its version and whose `roles` include its role, and whose `required_parameters` the module all has. It returns `%{card:, binding:}` or nil;
- `matches(node)` for the whole grid in one pass;
- `shown_parameters(node)` as a `MapSet` of `{module, param}`.

Production config lists no cards. Tests register a card from `test/support` with `Application.put_env/3`, restored in `on_exit`, so those test modules run `async: false` (as `AcquisitionCardTest` already does).

The behaviour lives in the web namespace because it renders. The system views of #123 can render the same `body/1` with the same assigns. That is why the body gets the binding and the node, and nothing dashboard-specific such as the grid or the selection.

*Alternatives:*
- `use SecantServiceWeb.SystemCard, system: …` (a macro): rejected. The project rules ask for no macros unless requested, and five small callbacks are not a burden.
- A compile-time registry (`@cards` in a module): rejected. Tests could not add a card without shipping it.
- Keying cards by a string such as `"PowerSupply:0.current"`: the three-part match (name, version list, role list) expresses "this card handles versions 0 and 1 of both roles" without listing every combination.

### 3. Shared chrome, custom body

`ModuleGrid` gains `system_card/1`. It renders the same `<article id={"card-" <> name}>` chrome as `module_card/1`: selection border, tint and edge, stale look, header with name and class, footer with the params button. The header gets a `PowerSupply:0 · current` badge, and the body is `match.card.body(assigns)`. The chrome markup moves into a private `card_shell/1` with an `inner_block` slot, shared by `module_card/1` and `system_card/1`, so the two cannot drift.

In `module_grid/1`, `SystemCards.matches(node)` is computed once per render. Only the "others" of each group (not controllers, not claimed channels) are looked up, which gives "acquisition modules keep their card" for free.

`SecantServiceWeb.SystemCards.Components` gives card authors small wrappers that build the routed ids:
- `card_param` (a `ParameterValueDisplay` with id `module_dash:<node>:<module>:<param>`, `location="module_dash"`);
- `card_status` (`ModuleIndicator` with the `module_indicator_mod:` id);
- `card_sparkline` (the existing `Sparkline` with `sparkline_id/2`);
- `card_command` (`CommandDisplay` with the `module_dash:` id).

The ids are the generic card's, so the existing `status`, `value`, `target` and sparkline routing reaches them unchanged.

### 4. Routing the declared parameters

`DashboardLive` keeps an assign `card_params`, a `{uuid, MapSet}` pair cached by the current node's uuid. It is recomputed from `SystemCards.shown_parameters/1` when the uuid differs, which happens at most once per description. Caching by uuid means none of the many places that set `current_node` (mount, node switch, `node_services_ready`, description change) needs to remember to refresh it.

`update_components/5` gets the set. For `{module, param}` in it, and `param` not already handled by `update_cards/4` (`status`, `value`, `target`, goals), it sends the update to `module_dash:<node>:<module>:<param>`. Cost: one `MapSet.member?/2` per reading in a batch.

*Alternative:* routing every parameter of every module to a `module_dash:` id and relying on `send_update` to a missing component being harmless. Rejected: hundreds of pointless sends per batch on a large node, and log noise.

### 5. Plot lines as data through `HistoryDB`

`PlotDB` gains an optional line definition argument: `lines(module, line_defs)`, `param_list(obj, line_defs)`, `plottable?(obj, line_defs)` and `init(obj, mode, line_defs)`, where nil (the default) keeps today's behaviour.

A line definition is `%{param: name, setpoint?: bool, hidden?: bool, y_axis: 0 | 1}`. `lines/2` resolves each with `Builders.find_param/2` and keeps those passing `History.thinnable?/1`, giving `series: name`. If the first definition doesn't survive, it falls back to `lines/1`. Every line map gains `y_axis` (0 for the interface-class lines).

`HistoryDB` takes a new optional assign `line_defs`, stored once on mount. Every existing call site passes it: the first load, the reloads, the range, window and overview fetches, and the live filter. The plot component id already changes with the session uuid, so a mounted `HistoryDB` never needs to pick up new definitions.

`ModuleDetail` computes `SystemCards.match(node, module)` and, when the card exports `plot_lines/1`, passes `line_defs` for the module plot (never for a parameter plot). It gates the plot on `PlotDB.plottable?(module, line_defs)` instead of `has_value`. The node browser gets this through the shared component.

**Second y-axis.** `TimePlot.build(Scalar, …)` passes the lines' `y_axis` to `Scalar.timeseries_option/…`. When a line has `y_axis: 1`, it builds `yAxis` as a two-element list: the primary unit left, and the first axis-1 line's unit right (`position: "right"`). It sets `yAxisIndex: 1` on those series and widens `grid.right` for the axis labels. Without such a line the option is the same map as today.

Enum, struct and array builds keep using the first line and at most one setpoint (`setpoint/1`). Custom setpoints get the `_held` hold, gaps and no band through the existing flags; only a series named `target` is dashed.

*Alternative:* `PlotDB.lines/1` looking up the card itself from the module's node. Rejected: it would make the data layer depend on the web registry and need the node (bindings live on the node, not the module) in every async fetch.

### Query count and payload on a long recording

A custom plot of k lines, s of them setpoints:
- **First load:** k window queries (each the existing bounded `History.window`: at most 400 buckets, or the raw-point budget), s "last reading before the window" queries for the holds, and 1 gaps query (2 for a session without spans). That is the same per-line cost as a Calibratable's 4 lines today.
- **Zoom, pan, range or overview:** k window queries, plus the gaps query of the reply, unchanged per line.
- **Payload:** k × the per-line point budget. Historical plots add one envelope band per non-setpoint number line, as today.

Nothing scales with recording length beyond what `History.window` already bounds. Cards add no queries: bindings and matching read the in-memory description, and card values come from `NodeTable`.

### Database

No migration. Readings, aggregates and hypertables are untouched.

## Risks / Trade-offs

- [A card body that raises crashes the dashboard LiveView for that node, because function components render in the LiveView process.] → Cards are code reviewed with the app. Each card ships with a LiveView test that renders it against a fixture node. The fallback rules (required parameters) keep a card off modules it wasn't written for.
- [A card shows a parameter it did not list in `shown_parameters`; that value then doesn't update live.] → The behaviour docs say so, and the test card's tests assert a live update for each shown parameter. A later change could derive the list by rendering the body once, if this bites.
- [`systems` arrives in a shape we haven't seen from a real node.] → `secant_client`'s parser keeps every node property except `modules` (`parser.ex:264`), so `systems` reaches `custom_properties` with atom keys (roles as atoms, module names as strings). The bindings tests cover both the fresh (atom-key) and the stored (string-key) shape through the real transform.
- [A second y-axis interacts with chart hook code written for one axis (the gap pass, live range).] → The hook already maps `yAxis` lists and bands copy `yAxisIndex`. A task checks a dual-axis plot in the browser for live extension, zoom and gaps before finishing.
- [Matching runs on every grid render.] → It is a pass over a small map (systems × roles) per render. The value batches don't re-render the grid; they go to components.

## Migration Plan

Nothing to migrate. With no cards configured the dashboard renders exactly as before, so rolling back is reverting the code.

## Open Questions

- Whether a card should be able to span two grid columns (a power supply card shows more than a single value). The chrome can take a width class later without changing the behaviour's other callbacks.
