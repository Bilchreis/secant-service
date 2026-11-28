# Design

## Context

See proposal.md (Why). The relevant state of the code:

**Where `systems` lands.**
- `secant_client`'s parser keeps every node property except `modules` (`parser.ex:264`), and `DescribeMessageTransformer.extract_custom_properties/1` drops only the standard ones. A node's `systems` property therefore ends up in `SecNode.custom_properties`.
- The dashboard does not use the transform's output directly. `NodeManager.ensure_record/1` upserts it and reloads the record (`node_manager.ex:278-286`), and `NodeValues.get_snapshot/1` serves that record. So the dashboard and the data browser both see `custom_properties` as stored JSON, with **string keys**. Atom keys only occur in the transform's output and in tests built from it.
- `SecantService.Acquisition.channel_map/1` already reads a property like this and accepts both key types. No code reads `systems` yet.

**Cards.** `ModuleGrid.module_grid/1` drops the channels that a controller claims (`Acquisition.channel_names/1`), groups the rest (`group_modules/1`), and splits each group into controllers (acquisition cards) and others (`module_card/1`). `module_card/1` owns:
- the chrome: the `card-<name>` id, selection border, `card_tint`/`card_edge`, the dashed look while stale, the header, and a footer holding both the `stop`/`go` buttons and the params button;
- the body: `ModuleIndicator`, the `value`/`target` `ParameterValueDisplay`s and the `Sparkline`.

The grid re-renders whenever `status_map` changes, which `put_status_color` does on every status reading (`index.ex:562`).

**Live values on cards.** `DashboardLive.handle_info({:value_updates, …})` calls `update_cards/4`, which routes only:
- `status` → `module_indicator(_mod):<node>:<module>`;
- `value`, `target` → `module_dash:<node>:<module>:<param>`;
- `goal`, `goal_enable` → `AcquisitionGoal`.

`ParameterValueDisplay` reads its first value from `NodeTable` on mount. It builds DOM ids from `param.id` and its `location`, and `set_parameter`/`validate_parameter` rebuild its component id from `location` (`index.ex:428-447`). So one parameter shown twice under one location gives duplicate ids.

**Module plot.** `PlotDB.lines(%Module{})` picks lines from `@class_lines` by the highest interface class, as `%{param:, series:, setpoint?:, hidden?:}`.

`TimePlot.plot/4` turns them into `lines: %{param_name => %{series:, dtype:}}`, one series per parameter. Everything downstream looks series up by parameter or series name:
- `PlotDB.trace_updates/3`;
- `Scalar.series_updates/3`, which falls back to series 0 when the name is missing (`scalar.ex:100`);
- `Bands` (`series_index`, `_envelopesBySeries` in the hook);
- the legend's `selected` map, which the hook keeps across rebuilds;
- the span-less gap fallback, which only takes `value` lines (`gaps.ex:157`).

`HistoryDB` calls `PlotDB.lines/1`, `param_list/1`, `plottable?/1` and `init/2` on its `secop_obj`. It does so at mount (`historyDB.ex:135`, falling back to a table via `tabular?/1`), on reloads, in the range, window and overview handlers (one `history_window!` per line), and to filter live readings (`param_list/1`, on every batch).

`ModuleDetail` mounts `HistoryDB` for the module when it has a `value` (`@has_value`), whether or not that value is plottable. A string value therefore shows as a table.

Readings come in two shapes. Live struct readings have atom keys for members named in the description (`parser.ex:113-119`, `existing_atom_or_string`). Stored readings are string-key JSON. `Struct.series_updates/3` already looks a field up both ways (`struct.ex:33-44`).

`History.window/4` thins structs and arrays by picking reading ids per channel and returns whole readings, bounded by its point budget.

**Chart hook.** It accepts a `yAxis` list (`echarts_chart.js:348`). `bands.js` copies a parent's `xAxisIndex`/`yAxisIndex`. The setpoint hold and the gap rules key off the `_held` flag, and the dashed style off `_target` (only on a series named `target`). Legend and tooltip show the series `name`.

## Goals / Non-Goals

**Goals:**
- One place that reads bindings, shared by the cards, the panel and, later, the system views.
- The plotting layer (`SecantService.PlotDB`) stays independent of the web layer. It gets a plot spec as plain data, never by looking up a definition.
- A module that matches nothing renders and plots exactly as today.
- Nothing about a custom plot can make the dashboard's LiveView raise on a reading.

**Non-Goals:**
- A plug-in or hot-loading mechanism. System modules are compiled and named in config.
- Isolating a raising card body from the rest of the node's dashboard (see Risks). A `rescue` around a function component cannot do it, because the rendered dynamic parts are evaluated after the call returns.
- Changing `PlotCache`, `NodeValues` or what gets recorded.

## Decisions

### 1. `SecantService.Systems`: bindings as a pure function of the node

A new module with a `Binding` struct: `local_name`, `system`, `version`, `role`, `description`, `module`, and `parents`, a list of `%{local_name, system, version, role}`, innermost first. It offers `bindings(node)` (`%{module_name => [Binding]}`) and `bindings_for(node, module_name)`.

- **Reading the property.** It reads `custom_properties["systems"] || custom_properties[:systems]` and normalises keys with `to_string/1`, creating no atoms.
- **Reference parsing** is one function, `parse_reference/1`, because RFC-104 defines no version syntax and this is our convention:
  - no `:` means version 0;
  - otherwise split on the last `:`; the suffix must match `~r/^\d+$/` and the name must be non-empty;
  - anything else drops the entry.
- **Two passes:**
  1. Per valid entry, each `role → value`: a value that is a module name gives a binding, since module names win over local names (RFC-104 forbids the clash). A value that is another entry's local name records a containment edge `{outer entry, role} → inner entry`. Anything else is skipped.
  2. Parents are resolved by walking containment edges outwards with a visited set, which cuts cycles. When several entries contain the same entry, the first by local name is followed.
- **Order:** bindings per module are sorted by `local_name`.

*Alternatives:*
- Storing bindings as Ash attributes or a table: rejected. They can be derived from the stored description and need no query.
- Adding a binding per containing system, e.g. `VectorMagnet:0.X.current`: rejected. The module's guarantees come from the inner schema, outer-keyed definitions would multiply with nesting depth, and a `PowerSupply` definition would stop matching inside a magnet.

### 2. System module + role modules, registered by config

Two behaviours, both callbacks required, returning nil for "none", so no `function_exported?/3` checks are needed. That check is false for a module not yet loaded in dev.

`SecantServiceWeb.SystemDefinition`, the system module:
- `system() :: String.t()`;
- `versions() :: [non_neg_integer()]`;
- `roles(version) :: %{String.t() => module()}`, a role module per customised role.

`roles/1` takes the version so that a later version can map a role to a different module without each role module carrying its own version list.

`SecantServiceWeb.SystemRole`, a role module:
- `required_parameters() :: [String.t()]`;
- `card() :: %{body: (map() -> Phoenix.LiveView.Rendered.t()), shown_parameters: [String.t()]} | nil`;
- `plot() :: SecantService.PlotDB.PlotSpec.t() | nil`.

`SecantServiceWeb.Systems`, the registry, reads `Application.get_env(:secant_service, :systems, [])` at call time and offers:
- `matches(node) :: %{module_name => %{system: mod, role: mod, binding: Binding}}`. Matching follows the module's bindings in order: system name → the first configured system module with that `system()` whose `versions()` include the version → `roles(version)[role]` → `required_parameters()` ⊆ the module's parameter names. The first full match wins.
- `shown_parameters(matches)`: a `MapSet` of `{module, param}`, built from the matched roles' cards.

`config/config.exs` documents `:systems` with an empty list. Tests register a test system from `test/support` with `Application.put_env/3`, restored in `on_exit`, and run `async: false`, as `AcquisitionCardTest` does.

**Matching once per description.**
- `DashboardLive` keeps an assign `systems` of `{uuid, matches, shown}`. It is recomputed when `current_node.uuid` differs, so none of the places that set `current_node` need to remember to refresh it.
- `ModuleGrid` and `ModuleDetail` receive `matches` as an attribute and never match on their own.
- The node browser computes `matches` once when it loads a session.
- The system views of #123 can call the same `matches/1`.

*Alternatives:*
- Role modules declaring their own system and role, with config listing them: rejected. It duplicates the schema in every child, allows two children to claim a role, and gives the system views no role map.
- A `use` macro: rejected by the project rules.

### 3. Shared chrome with body and footer slots

`ModuleGrid` gets a private `card_shell/1`. It renders the `<article id={"card-" <> name}>` chrome (selection border, tint and edge, stale look, header with name and class) and takes three slots:
- `:badge`, in the header;
- `:inner_block`, the body;
- `:actions`, footer content left of the params button.

`module_card/1` passes the generic body and `stop`/`go` as actions, and its rendered markup stays the same. `system_card/1` passes:
- a badge with id `card-<name>-system`, `PowerSupply:0 · current`, and `data-system="PowerSupply:0"`, `data-role="current"` on the article;
- the role's `card().body` with assigns `module`, `node`, `node_id_str`, `binding`, `node_state`, `status` and `location`;
- no actions; the body includes the commands it wants.

The host passes `location`: `"module_dash"` on the dashboard. A system view will pass its own, so ids don't collide.

In `module_grid/1`, only the "others" of each group (not controllers, not claimed channels) look up `matches`, so acquisition modules keep their card. A match whose role has no card renders `module_card/1`.

`SecantServiceWeb.Systems.Components` gives card bodies small wrappers that build the routed ids from `node`, `module` and `location`:
- `card_param`, a `ParameterValueDisplay` with id `<location>:<node>:<module>:<param>`;
- `card_status`, a `ModuleIndicator` with the `module_indicator_mod:` id;
- `card_sparkline`, the existing `Sparkline` with `sparkline_id/2`;
- `card_command`, a `CommandDisplay`.

The behaviour docs state that a body shows each parameter at most once.

### 4. Routing the shown parameters

`update_components/5` receives the cached `shown` set. For `{module, param}` in it, with `param` not one of those `update_cards/4` already sends (`status`, `value`, `target`, `goal`, `goal_enable`), it sends the update to `module_dash:<node>:<module>:<param>`. That costs one `MapSet.member?/2` per reading.

The set and the skip rule live in a small pure function, `card_route/3`, which is unit-tested. LiveViewTest cannot observe a `send_update` to a missing component.

*Alternative:* routing every parameter of every module to a `module_dash:` id. Rejected: hundreds of pointless sends per batch on a large node, plus log noise.

### 5. Plot specs, traces and one fetch per parameter

**Data shape** (in `SecantService.PlotDB.PlotSpec`, plain structs):
- `%PlotSpec{axes: [%{name: nil | String.t(), unit: nil | String.t()}] (0–2), traces: [%Trace{}]}`.
- `%Trace{param: String.t(), path: [String.t() | non_neg_integer()], each: boolean(), label: nil | String.t() | {:path, [..]} | {:param, String.t(), [..]}, setpoint?: boolean(), hidden?: boolean(), axis: 0 | 1}`.
- `each: true` makes `path` lead to an array, drawn per element; a `{:path, p}` label is then read at `p ++ [i]`.

**Resolving** (`PlotDB.traces(module, spec)`, pure apart from the label reads):
1. Each trace's parameter is looked up with `Builders.find_param/2`. It is kept when the declared datainfo gives a number at its path (walking struct `members` and array `members`).
2. `each` traces expand to `Channels.declared_length(datainfo_at_path)`, or the length of the latest reading's array.
3. The list is cut to 16.
4. Each resolved trace gets a stable series name. A whole parameter keeps its parameter name (`value`, `target`), so the `target` style and the `value` gap fallback keep working. A path gets `param.path`, e.g. `value.composition[2]`.
5. No resolved trace means the generic `lines/1`.

**Labels** are read once, in the first load's async task:
- from the latest reading in the first window of the trace's own parameter;
- for `{:param, …}`, from one `ArrayLatest.fetch_latest/1`-style query of the latest reading of that parameter.

They go on the series as `_label`. The hook's legend `formatter` and tooltip show `_label || name`, which is a small change in `echarts_chart.js`. The series `name` stays the stable key for updates, bands and `legend.selected`.

**Building.** `TimePlot` gets a `build_custom/3` for the number-line drawing:
- one `Builders.fetch_param_window`, or the held fetch for a parameter with a setpoint trace, per **distinct parameter**;
- each trace's values extracted from that window;
- the result goes through the same `Scalar` series, `Bands.put/3` and `Gaps.put/3` as today.

`Bands.eligible?/1` additionally requires an empty path. The span-less gap fallback already takes only a series named `value`.

A custom plot's map carries `traces: %{param_name => [%{series:, path:}]}` (each element trace's path ends in its index) instead of `lines`. `trace_updates/3` fans a parameter's readings out to its traces.

**Extraction** is one function, `Trace.extract(value, path)`, that never raises:
- each step looks the key up as a string, then as an existing atom (the `Struct.series_updates` lookup), or indexes an array;
- anything that is not a number gives `nil`, i.e. no point.

It is used for the first load, windows and live updates alike. `Scalar.series_updates/3` returns `[]` instead of falling back to series 0 when the name is missing.

**Resolve once, use everywhere.**
- `HistoryDB` takes an optional `plot_spec` assign. On mount it uses `PlotDB.plottable?(module, spec)` (and its table fallback is unchanged when `spec` is nil).
- After the first load, the range, window and overview handlers and the live filter read the parameters and traces from the loaded plot (`plot.traces`), not from `PlotDB.lines/1` again. That removes the per-batch `find_param` and guarantees the first load, windows and live updates agree on traces, labels and element counts.
- Plots without a spec are untouched: they keep `lines` and today's `PlotDB.lines/1` calls. The handlers branch once on whether the loaded plot carries `traces`, so enum, struct, heatmap and interface-class plots keep exactly today's code path.

**Gate.** `ModuleDetail` shows the plot when `@plot_parameter || @has_value || custom plot drawable`, so a module that matches nothing keeps today's table for a non-plottable `value`.

**Second y-axis.** When a resolved trace has `axis: 1`, `Scalar.timeseries_option` builds `yAxis` as a two-element list:
- left: the spec's axis 0 name/unit, else the first axis-0 trace's unit;
- right: likewise, with `position: "right"` and the name aligned right;
- `yAxisIndex: 1` on its series, and a wider `grid.right`.

Without such a trace the option is the same map as today.

*Alternatives:*
- Re-resolving `lines` at every call site (the earlier draft): rejected. It costs a `find_param` per reading per batch, and windows could disagree with the first load once labels and counts are fixed at build time.
- Labels as series names: rejected. Duplicate or changing gas names would misroute updates and lose the legend's hidden state.
- Several panels: deferred (proposal). They would merge the struct multi-grid builder with the gap- and band-aware number-line builder that #181 just separated.

### Query count and payload on a long recording

A custom plot drawing p distinct parameters (s of them with a setpoint trace), with l parameters used only for labels:
- **First load:** p window queries (each the existing bounded `History.window`: at most 400 buckets, or the raw-point budget), s "last reading before the window" queries for the holds, l latest-reading queries for labels, and 1 gaps query (2 for a session without spans).
- **Zoom, pan, range or overview:** p window queries, plus the reply's gaps query. Per-element traces of one array cost one query, not one each.
- **Payload:** at most 16 traces × the per-parameter point budget.
  - Struct readings are thinned by picking readings, so the server holds a bounded number of whole readings and sends only the extracted numbers.
  - Historical plots add one band per whole, non-setpoint number trace, as today.

Nothing scales with recording length beyond what `History.window` already bounds. Cards add no queries: matching reads the in-memory description, and card values come from `NodeTable`.

### Database

No migration. Readings, aggregates and hypertables are untouched.

## Risks / Trade-offs

- [A card body or role callback that raises crashes the node's dashboard LiveView on every render, a crash loop for everyone viewing that node.] → Mitigations:
  - recording is unaffected: `NodeValues`, `PlotCache`, the DB writer and the tracker are separate processes;
  - the required-parameter gate keeps a card off modules it wasn't written for;
  - each production system must ship with a LiveView test that renders its cards against a fixture;
  - plot code runs in `start_async` (a raise fails only the plot), and live extraction cannot raise by construction (Decision 5).
- [A card shows a parameter it did not list in `shown_parameters`; that value then doesn't update live.] → The behaviour docs say so, and the test system's tests assert a live update for each shown parameter.
- [Labels go stale when, e.g., the gas list changes during a long live session.] → Accepted and specified: labels refresh when the plot loads again. Lines stay correct, because they are keyed by stable names.
- [Hook code written for one y-axis (the gap pass, the live range, `_setSlider`).] → The hook maps `yAxis` lists and bands copy `yAxisIndex`. Task 6.1 checks a two-axis plot in the browser for live extension, zoom and gaps.

## Migration Plan

Nothing to migrate. With no systems configured the dashboard renders exactly as before, so rolling back is reverting the code.

## Open Questions

- Whether a card should be able to span two grid columns. The shell can take a width class later without changing the behaviours.
