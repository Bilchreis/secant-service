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
  2. Parents are resolved by walking containment edges outwards with a visited set, which cuts cycles. When several entries contain the same entry, the first by local system name is followed.
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
- `DashboardLive` keeps an assign `systems` of `{uuid, matches, shown}`. A DashboardLive helper, `assign_systems/1`, recomputes it when `current_node.uuid` differs, piped after each `Model.to_socket/2` call (`index.ex:49`, `80`, `140`). `SecantService.Model` is core and must not call the web registry.
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

The host passes `location`: `"module_dash"` on the dashboard. A system view will pass its own, so `card_param` and `card_command` ids don't collide. `card_status` and `card_sparkline` keep the fixed ids that today's routing reaches (`module_indicator_mod:…`, `sparkline_id/2`), so a page shows a module's status and sparkline at most once. `card_sparkline` wraps the generic `value`/`target` sparkline only.

A system card's params button shows the module's parameter count and all of its commands as "· N cmds", since the card chooses which commands it shows.

In `module_grid/1`, only the "others" of each group (not controllers, not claimed channels) look up `matches`, so acquisition modules keep their card. A match whose role has no card renders `module_card/1`.

`SecantServiceWeb.Systems.Components` gives card bodies small wrappers that build the routed ids from `node`, `module` and `location`:
- `card_param`, a `ParameterValueDisplay` with id `<location>:<node>:<module>:<param>`;
- `card_status`, a `ModuleIndicator` with the `module_indicator_mod:` id;
- `card_sparkline`, the existing `Sparkline` with `sparkline_id/2`;
- `card_command`, a `CommandDisplay`.

The behaviour docs state that a body shows each parameter at most once.

### 4. Routing the shown parameters

`update_components` gains the cached `shown` set as a sixth argument, so routing stays a pure function of its inputs. For `{module, param}` in it, with `param` not `value` or `target` (the only ones `update_cards/4` already sends to a `module_dash:` id), it sends the update to `module_dash:<node>:<module>:<param>`. `status`, `goal` and `goal_enable` go to other components today (`ModuleIndicator`, `AcquisitionGoal`), so a card that shows them with `card_param` gets them routed here. That costs one `MapSet.member?/2` per reading.

The set and the skip rule live in a small pure function, `card_route/3`, which is unit-tested. LiveViewTest cannot observe a `send_update` to a missing component.

*Alternative:* routing every parameter of every module to a `module_dash:` id. Rejected: hundreds of pointless sends per batch on a large node, plus log noise.

### 5. Plot specs, traces and one fetch per parameter

**Data shape** (in `SecantService.PlotDB.PlotSpec`, plain structs):
- `%PlotSpec{axes: [%{name: nil | String.t(), unit: nil | String.t()}] (0–2), traces: [%Trace{}]}`.
- `%Trace{param: String.t(), path: [String.t() | non_neg_integer()], each: boolean(), label: nil | String.t() | {:path, [..]}, setpoint?: boolean(), hidden?: boolean(), axis: 0 | 1}`.
- `each: true` makes `path` lead to an array, drawn per element; a `{:path, p}` label is a path in the same parameter's value, read at `p ++ [i]` for element `i`.
- Labels from another parameter are not in this change. No current use needs them, and they would cost a query per label parameter.

**Checking without the database** (`PlotDB.drawable?(module, spec)`): true when some trace's parameter exists and its declared datainfo gives a number at its path, walking struct `members` and array `members`. It reads the description only, so `ModuleDetail` and `HistoryDB.update/2` can call it while rendering.

**Resolving** (`PlotDB.traces(module, spec, latest)`, called inside the first load's async task):
1. Each trace's parameter is looked up with `Builders.find_param/2`. It is kept when `drawable?` holds for it.
2. `each` traces expand to `Channels.declared_length(datainfo_at_path, max: 16)`, else the length of `latest` (the latest reading in the first window), and never past the slots left under the cap, so a 350 000-element declaration never builds 350 000 traces.
3. The list is cut to 16.
4. Each resolved trace gets a stable series name. A whole parameter keeps its parameter name (`value`, `target`), so the `target` style keeps working. A path gets `param.path`, e.g. `value.composition[2]`.
5. Traces with the same series name are deduplicated, first wins.
6. No resolved trace means the generic `lines/1`.

**Labels** are read once, in the first load's async task, from the latest reading in the first window of the trace's own parameter. When that window is empty (e.g. a live window with no reading yet), the fallback labels are used; that is accepted. Labels go on the series as `_label`. Three places show them, each escaping with `escHtml` from `common.js`, because labels come from node readings:
- the legend's `formatter` in `echarts_chart.js`;
- a formatter for the number plots' axis tooltip, which today is ECharts' default (`Scalar.timeseries_option`, `tooltip: %{trigger: "axis"}`), showing `_label || seriesName`;
- `bands.js` `_envelopeTooltip`, the tooltip of historical plots with bands, which prints `seriesName` today.

The series `name` stays the stable key for updates, bands and `legend.selected`.

**Building.** `TimePlot` gets a `build_custom/3` for the number-line drawing:
- one `Builders.fetch_param_window`, or the held fetch for a parameter with a setpoint trace, per **distinct parameter**;
- each trace's values extracted from that window;
- the result goes through the same `Scalar` series, `Bands.put/3` and `Gaps.put/3` as today.

A custom plot carries both:
- `lines`: one line-shaped entry per resolved trace, `%{param:, series:, path:, setpoint?:, hidden?:, axis:}`, built like `TimePlot.plot/4`'s;
- `traces: %{param_name => [entry]}`, the fan-out map for live readings.

Because `lines` keeps today's shape, `Gaps.put/3`/`reply/4`, `Bands.put/3`/`reply` and `HistoryDB`'s line-based handlers match custom plots unchanged. Two rules gain a path check:
- `Bands.eligible?/1` requires an empty path;
- `Gaps.fallback/2`, which matches a line whose `param` is named `value` (`gaps.ex:157`), requires an empty path too, so `value.composition[2]` never gets the poll-interval estimate.

`trace_updates/3` fans a parameter's readings out through `traces`.

**Extraction** is one function, `Trace.extract(value, path)`, that never raises:
- each step looks the key up as a string, then as an existing atom (the `Struct.series_updates` lookup), or indexes an array;
- anything that is not a number gives `nil`, i.e. no point.

It is used for the first load, windows and live updates alike. `Scalar.series_updates/3` returns `[]` instead of falling back to series 0 when the name is missing.

**Resolve once, use everywhere.**
- `HistoryDB` takes an optional `plot_spec` assign. On mount it checks `PlotDB.drawable?(module, spec)` when a spec is given; without one, its `plottable?`/table fallback is unchanged.
- After the first load of a custom plot, the range, window and overview handlers and the live filter read the parameters from the loaded plot's `lines`, not from `PlotDB.lines/1` again. They fetch once per distinct `line.param.id` and fan out. That removes the per-batch `find_param` and guarantees the first load, windows and live updates agree on traces, labels and element counts.
- Plots without a spec are untouched and keep today's `PlotDB.lines/1` calls. The handlers branch once on whether the loaded plot carries `traces`, so enum, struct, heatmap and interface-class plots keep exactly today's code path.

**Gate.** `ModuleDetail` shows the plot when `@plot_parameter || @has_value || PlotDB.drawable?(module, spec)`, so a module that matches nothing keeps today's table for a non-plottable `value`.

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

A custom plot drawing p distinct parameters (s of them with a setpoint trace):
- **First load:** p window queries (each the existing bounded `History.window`: at most 400 buckets, or the raw-point budget), plus the small per-parameter queries today's fetch already makes (a historical fetch's plot start, the held fetch's "last reading before the window" for the s setpoint parameters), and 1 gaps query (2 for a session without spans). Labels need no query; they come from the fetched window.
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
- [Labels are untrusted text from node readings, and the new formatters replace ECharts' own escaping.] → Every formatter escapes with `escHtml`; a `node --test` case uses a `<b>` label.

## Migration Plan

Nothing to migrate. With no systems configured the dashboard renders exactly as before, so rolling back is reverting the code.

## Open Questions

- Whether a card should be able to span two grid columns. The shell can take a width class later without changing the behaviours.
