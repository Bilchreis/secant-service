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

A new module, with a `Binding` struct in its own file (`lib/secant_service/systems/binding.ex`, per the project's no-nesting rule): `local_name`, `system`, `version`, `role`, `description`, `module`, and `parents`, a list of `%{local_name, system, version, role}`, innermost first. It offers `bindings(node)` (`%{module_name => [Binding]}`) and `bindings_for(node, module_name)`.

**Total by construction.** `bindings/1` runs in the dashboard's mount and `handle_info` and in the node browser's mount, on data the node controls, so it must never raise:
- a `systems` value that is not a map gives `%{}`;
- an entry that is not a map is skipped;
- a role key or value that is neither a string nor an atom is skipped, never passed to `to_string/1`.

- **Reading the property.** It reads `custom_properties["systems"] || custom_properties[:systems]` and normalises atom keys with `Atom.to_string/1`, creating no atoms.
- **Reference parsing** is one function, `parse_reference/1`, because RFC-104 defines no version syntax and this is our convention:
  - no `:` means version 0;
  - otherwise split on the last `:`; the suffix must match `~r/\A\d+\z/` (not `^…$`, which accepts `"1\n"`) and parse with `Integer.parse/1` to `{n, ""}`, and the name must be non-empty;
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
- `plot() :: SecantService.PlotDB.LinesPlot.t() | SecantService.PlotDB.ArrayPlot.t() | nil`.

`SecantServiceWeb.Systems`, the registry, reads `Application.get_env(:secant_service, :systems, [])` at call time and offers:
- `matches(node) :: %{module_name => %{system: mod, role: mod, binding: Binding}}`. Matching follows the module's bindings in order: system name → the first configured system module with that `system()` whose `versions()` include the version → `roles(version)[role]` → `required_parameters()` ⊆ the module's parameter names. The first full match wins.
- `shown_parameters(matches)`: a `MapSet` of `{module, param}`, built from the matched roles' cards.

`config/config.exs` documents `:systems` with an empty list. Tests register a test system from `test/support` with `Application.put_env/3`, restored in `on_exit`, and run `async: false`, as `AcquisitionCardTest` does.

**Matching once per description.**
- `DashboardLive` keeps an assign `systems` of `{uuid, bindings, matches, shown}`. A DashboardLive helper, `assign_systems/1`, recomputes it when `current_node.uuid` differs, piped after each `Model.to_socket/2` call (`index.ex:49`, `80`, `140`). `SecantService.Model` is core and must not call the web registry.
- `ModuleGrid` receives `matches`. `ModuleDetail` receives `matches` and `bindings`; it needs the bindings to show membership for unmatched modules. Neither computes them on its own.
- The node browser computes `bindings` and `matches` once when it loads a session.
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

*Alternative:* routing every parameter of every module to a `module_dash:` id. Rejected: hundreds of pointless sends per batch on a large node. A `send_update` to a missing component is a silent no-op, so the cost is the only problem.

### 5. Plot specs: lines plots and array plots

**Data shape.** Plain structs, each in its own file under `lib/secant_service/plot_db/`:
- `%LinesPlot{axes: [%{name: nil | String.t(), unit: nil | String.t()}] (0–2), traces: [%Trace{}]}`;
- `%ArrayPlot{labels: %LabelSource{} | nil, axis_name: nil | String.t()}`. It always draws the module's `value`; its label source must name a parameter;
- `%Trace{param: String.t(), path: [String.t()], pick: nil | {:index, non_neg_integer()} | :each | {:match, %LabelSource{}, number()}, label: nil | String.t() | %LabelSource{}, setpoint?: boolean(), hidden?: boolean(), axis: 0 | 1}`:
  - `path` runs through struct fields only;
  - `pick` chooses an element when the path ends at a numeric array;
- `%LabelSource{param: nil | String.t(), path: [String.t()], template: nil | String.t()}`. A nil `param` means the trace's own parameter. For `:each` traces and array plots the source must lead to an array, read at the element's index.

A role's `plot()` returns a `LinesPlot`, an `ArrayPlot` or nil.

**Why array plots draw only `value`.** Today's array path, the live filter (`historyDB.ex:201`, `PlotDB.param_list/1`) and the range, window and overview handlers (`historyDB.ex:306`, `380`, `427`, `PlotDB.lines/1`) all work from the module's generic lines, which start with `value` (`plot_db.ex:65-85`). Drawing another parameter would need a second code path through all of them. Custom plots already apply only to modules with a `value`, and the motivating mass spectrum is the `value`.

**Numbers.** A trace draws what `Scalar.supported_type?/1` accepts (`double`, `int`, `scaled`), at its path. Enums are not number traces; the generic plot draws them as bands. An axis's fallback unit is read along the trace's path: the struct member's `unit`, or for an array element the array's `members.unit`, as `ArrayHeatmap.unit/1` does.

**What can be drawn** (`PlotDB.drawable?(module, spec)`) reads the description only and never raises: it checks `is_map` at every step of the path before reading `members` or `maxlen`, so malformed datainfo gives false. `ModuleDetail` and `HistoryDB.update/2` therefore call it while rendering.
- A trace is drawable when:
  - its parameter exists and `History.thinnable?/1` holds for it (no array-of-struct paths);
  - its path walks struct `members` to a number, or to a numeric array, with a `pick`;
  - that array's declared length (`Channels.declared_length/1`) is at most `TimePlot.max_array_len/0` (100), or undeclared.
- An `ArrayPlot` is drawable when the module's `value` is a numeric array (`ArrayLatest.numeric_array?/1`).

**Latest values** come from a small helper, `PlotDB.latest_value(param)`: `SecNodes.latest_reading` and `Storage.raw_value`, for any value. `ArrayLatest.fetch_latest/1` returns nil for anything that isn't a list (`array_latest.ex:33-36`), so it can't serve a struct `value`.

**Resolving a lines plot** (`PlotDB.traces(module, spec)`, inside the first load's async task):
1. Drop traces that are not drawable.
2. **Before any window fetch**, read `latest_value` once for each parameter that has an element trace into an array with no declared length, and drop those traces when the array is longer than 100. The generic path does the same check first (`long_array`, `plot_db.ex:113-121`). SECoP makes `maxlen` mandatory, so only nonconforming nodes pay this query.
3. Read `latest_value` once for each parameter the remaining traces need for labels, `:each` lengths or `:match` lookups. A trace's own parameter reuses the value from step 2 if it has one.
4. Expand `:each` to `min(declared length || latest length, 100)` traces.
5. Resolve `{:match, source, x}` with `==` (so 28 matches 28.0) to the first matching index; none drops the trace. **Every resolved pick is a concrete `{:index, k}`**, so no later window or zoom can re-resolve it.
6. Name each trace stably. A whole parameter keeps its name (`value`, `target`), so the `target` style keeps working. A struct path gives `value.composition`, and a picked element appends `[k]`, e.g. `value.composition[2]` or `value[27]`.
7. Deduplicate by name, the first wins.
8. Cut the list to 16.
9. If no trace is left, return `:no_traces`; `init` then falls back (below).

Arrays wider than 16 elements are thinned by whole-array extremes (`Channels`), so zoomed-out element traces can miss short spikes, as the generic heatmap does.

**Label text** (`LabelSource.text/2`, pure, never raises):
- a string is used as it is;
- a whole number is written without a fraction (28.0 → `28`), any other number in its shortest form (`:erlang.float_to_binary(x, [:short])`);
- a template replaces `{}` with that text;
- anything else gives nil.

A nil label falls back to the trace name, or for an index to its number. Labels, picked indexes and element counts are read once and stay fixed until the plot loads again.

**Building a lines plot.** `TimePlot.build_lines/3`:
- one `Builders.fetch_param_window` per **distinct parameter** (the held fetch when it has a setpoint trace);
- each trace's values extracted from that window by `Trace.extract/3`;
- the result through the same `Scalar` series, `Bands.put/3` and `Gaps.put/3` as today.

A reading with no number where a trace reads gives that trace **no point**: it is dropped, not sent as `[ts, nil]`, so a transient error reading doesn't break the line.

The plot map then carries:
- `lines`: a map keyed by **series name**, `%{series => %{series:, dtype: Scalar}}`. A custom plot can have several traces of one parameter, so it can't be keyed by parameter like `TimePlot.plot/4`'s. Its consumers (`Gaps.put/3`, `reply/4`) only match on the key's presence.
- `resolved`: the list shape of `PlotDB.lines/1`, one entry `%{param:, series:, path:, pick: {:index, k} | nil, setpoint?:, hidden?:, axis:}` per trace. It is passed where `Gaps` and `Bands` take plot lines, and the `HistoryDB` handlers read it.
- `traces: %{param_name => [entry]}`. `trace_updates/3` matches it in a clause before its `lines` clause, fanning a parameter's readings out by extraction.

The handlers' `window_reply/2` calls `trace_updates/3` once per **distinct parameter** (not once per trace, which would send N² updates), and builds envelopes per trace.

The span-less gap estimate (`Gaps.fallback/2`, `gaps.ex:157`) applies only to a whole parameter: `path == [] and pick == nil`. So `value.composition[2]` and `value[27]` never get it. `Bands.eligible?/1` needs no change, because a trace into a struct or array belongs to a parameter it already rejects (`bands.ex:15-16`), and a band is built only for a whole-parameter trace.

**Falling back.** `PlotDB.init(module, mode, spec)` returns `PlotDB.init(module, mode)` when a lines plot resolves to `:no_traces`. When the result is `%{plottable: false}` (e.g. a string `value`), `HistoryDB.handle_async(:load_plot, …)` switches to the table when `tabular?/1` holds, instead of leaving an empty chart (`historyDB.ex:597`, `816-836`).

**Building an array plot.** `PlotDB.init` with an `ArrayPlot` follows today's array path for `value` (`long_array`, then `ArrayHeatmap` or `ArrayLatest`). It reads the label source once with `latest_value` and adds:
- for a heatmap, `_indexLabels`: the texts of the first `min(length of the source, 100)` entries. They're taken from the source, not from the array's length at load, so rows added as the array grows live keep their labels;
- for a latest-reading plot, `_indexLabels` only when the source has at most 4000 entries (`@max_points`, `array_latest.ex:16`), where every index is drawn. Above that, `ArrayLatest.points/1` keeps per-chunk extremes whose indexes change from reading to reading (`array_latest.ex:174-190`), and the axis ticks need arbitrary indexes, so those plots show index numbers;
- the axis name, set on the server in the index axis's `name` (`ArrayHeatmap.index_axis/1`, `ArrayLatest.option/3`), with no new hook key.

`HistoryDB` keeps the `ArrayPlot` spec. `rebuild_as_latest/3`, which already runs in `start_async` (`historyDB.ex:96`), reads the label source again (one query) and applies the rule above. A rebuild is a reload, so this is consistent with labels staying fixed until the plot loads again. The FTIR-like case, which starts at 3 points and fills to 10 000, gets its labels on the rebuild, if they fit.

**Extraction** (`Trace.extract(value, path, index)`, where `index` is nil for traces without a pick) never raises:
- each step takes the string key, or the key whose `to_string/1` equals it (the scan `Struct.series_updates` does, `struct.ex:39-46`, creating no atoms), or indexes a list;
- anything that is not a number gives nil.

The first load, windows and live updates all use it. `Scalar.series_updates/3` returns `[]` instead of falling back to series 0 when a name is missing. That also applies to generic struct plots through `struct.ex:56`, and is intended: a missing series must not overwrite series 0. A regression test covers generic struct plots.

**Labels in the browser.** Labels come from node readings, so they are untrusted.
- Canvas text and `textContent` get the raw label. ECharts draws the legend and axis labels on canvas (`LegendView.js:326`), where HTML escaping would show `&lt;`.
- HTML tooltips escape it.
- `escHtml` moves from `common.js` into a new pure `assets/js/charts/labels.mjs`, which `common.js` re-exports. `common.js` creates observers at load time (lines 103, 115, 135), so a test can't import it.

The places that show labels:
- **Lines plots:**
  - the legend formatter (canvas, raw);
  - a new axis-tooltip formatter for number plots, installed only when some series has `_label`, so generic plots keep ECharts' default tooltip (escaped);
  - `bands.js` `_envelopeTooltip` (escaped).
- **Array plots with `_indexLabels`:**
  - the heatmap index-axis formatter (canvas, raw);
  - the heatmap hover readout (`textContent`, `arrays.js:137`, raw);
  - lines mode, which has no legend: its series keep the `[i]` names, and `_linesTooltip` looks the label up by element index (escaped). Renaming the series would merge equal labels through its `seen` set (`arrays.js:356`) and double-escape them;
  - `ArrayLatest`'s index-axis formatter (canvas, raw) and its tooltip (`arrays.js:203-206`, escaped).

ECharts' canvas text still interprets its own rich-text syntax (`{style|text}`) in formatter output. That is accepted: it can restyle a label, but cannot inject HTML or script.

The series `name` stays the stable key for updates, bands and `legend.selected`.

**Resolve once, use everywhere.**
- `HistoryDB` takes an optional `plot_spec` assign, checks `drawable?` on mount when it is given, and passes it to `init` on mount, on reloads and on `rebuild_as_latest`.
- After a custom lines plot's first load, the range, window and overview handlers and the live filter read `plot.resolved`, not `PlotDB.lines/1`. They fetch once per distinct `param.id` and fan out, so the first load, windows and live updates agree on traces, labels and picked elements.
- Array plots draw `value`, so they keep today's handlers.
- The handlers branch once on whether the loaded plot carries `traces`.

**Gate.** `ModuleDetail` keeps today's `@plot_parameter || @has_value`, and passes the role's plot only when the module has a `value`. A module without `value` keeps today's panel. That avoids a module plot with no table parameter: `HistoryDB`'s Table tab and CSV link use `value` (`historyDB.ex:47-55`, `735-738`).

**Second y-axis.** When a lines plot has a trace with `axis: 1`, `Scalar.timeseries_option` builds `yAxis` as a two-element list:
- left: the spec's axis-0 name and unit, else the unit of the first axis-0 trace (read along its path);
- right: likewise, from axis 1, with `position: "right"` and the name aligned right;
- `yAxisIndex: 1` on its series, and a wider `grid.right`.

Without such a trace the option is the same map as today.

*Alternatives:*
- **Re-resolving lines at every call site** (an earlier draft): rejected. It costs a `find_param` per reading per batch, and windows could disagree with the first load.
- **Labels as series names:** rejected. Duplicate or changing labels would misroute updates and lose the legend's hidden state.
- **A new heatmap builder for labelled arrays:** rejected. Labelling today's array plot reuses its thinning, lines mode and long-array handling.
- **Array plots of any parameter:** rejected for now. It would need a second code path through the live filter and every window handler.
- **Several panels:** deferred (proposal). They would merge the struct multi-grid builder with the gap- and band-aware number-line builder that #181 just separated.

### Query count and payload on a long recording

Each "window fetch" below is today's per-parameter fetch: several SQL statements, a count and the thinning or aggregate query with its head and tail. A historical fetch also always runs the plot start and the hold (`builders.ex:173-206`), for every parameter. The cost grows with **distinct parameters**, not traces.

A lines plot drawing p distinct parameters (s with a setpoint trace), needing latest values for q parameters (label sources, `:each` lengths, `:match` lookups, and the pre-check of undeclared arrays), costs:
- **First load:** q latest-value queries, then p window fetches (plus the s live holds' "last reading before the window"), and 1 gaps query (2 for a session without spans).
- **Zoom, pan, range or overview:** p window fetches and the reply's gaps query. N element traces of one array cost the same as one trace of it.
- **Payload:** at most 16 traces, each bounded by its parameter's point budget.
  - Historical windows are thinned by `History.window`.
  - A live window reads the raw readings of its range (`builders.ex:78-89`), as today's live plots do. Element traces only read arrays of at most 100 elements, so a live load is never larger than today's live heatmap of the same parameter.
  - Struct and array readings are thinned by picking readings; only the extracted numbers are sent.

An array plot costs what today's array plot of `value` costs, plus one latest-value query for its label source on load and on a rebuild. The payload grows by at most 100 short strings for a heatmap, and at most 4000 for a latest-reading plot. Cards add no queries: matching reads the in-memory description, and card values come from `NodeTable`.

### Database

No migration. Readings, aggregates and hypertables are untouched.

## Risks / Trade-offs

- [A card body or role callback that raises crashes the node's dashboard LiveView on every render, a crash loop for everyone viewing that node.] → Mitigations:
  - recording is unaffected: `NodeValues`, `PlotCache`, the DB writer and the tracker are separate processes;
  - the required-parameter gate keeps a card off modules it wasn't written for;
  - each production system must ship with a LiveView test that renders its cards against a fixture;
  - plot building runs in `start_async` (a raise fails only the plot);
  - the code that runs in the LiveView process on node-controlled data is total by construction and tested on malformed input: `bindings/1`, `drawable?/2`, `Trace.extract/3` and `LabelSource.text/2`.
- [A latest-reading plot of an array longer than 4000 elements shows index numbers, not labels.] → Accepted and specified: its drawn indexes change from reading to reading. A label source of a different length than the array labels what it covers.
- [A card shows a parameter it did not list in `shown_parameters`; that value then doesn't update live.] → The behaviour docs say so, and the test system's tests assert a live update for each shown parameter.
- [Labels and elements picked by label value go stale when, e.g., the gas list or the mass table changes during a long live session.] → Accepted and specified: they refresh when the plot loads again. A changed `_mass` can make a trace picked "by mass 28" show another mass until then. Lines stay keyed by stable names, so updates are never misrouted.
- [Hook code written for one y-axis (the gap pass, the live range, `_setSlider`).] → The hook maps `yAxis` lists and bands copy `yAxisIndex`. Task 6.1 checks a two-axis plot in the browser for live extension, zoom and gaps.
- [Labels are untrusted text from node readings, and the new formatters replace ECharts' own escaping.] → HTML tooltips escape with `escHtml`; canvas text (the legend, axis labels) gets the raw label. A `node --test` case checks both with a `<b>` label.

## Migration Plan

Nothing to migrate. With no systems configured the dashboard renders exactly as before, so rolling back is reverting the code.

## Open Questions

- Whether a card should be able to span two grid columns. The shell can take a width class later without changing the behaviours.
