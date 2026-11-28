# Proposal

## Why

Everything on the live dashboard is built generically from a module's self-description: the card shows `value`, `target`, `status` and `stop`/`go`, and the module plot draws the lines its interface class names. A module that is part of a SECoP *system* (RFC-104, e.g. the proposed [`PowerSupply:0`](https://github.com/SampleEnvironment/SECoP/blob/master/schema/proposed/power_supply.yaml)) comes with a schema that guarantees more: which role it plays in the system and which extra parameters it has (a mass flow controller's gas type, a power supply's `control_active` and limits). The dashboard ignores that and can't show it. This change lets the app ship tailored cards and module plots for system modules, as a step towards the system views of issue #123.

## What Changes

- **Read a node's systems.** The node property `systems` (already stored in the node's custom properties) is read into *bindings*: for every module the systems it belongs to, as `{local system name, system name, version, role}`.
  - The role is the module name the system definition gives it (`current` in `PowerSupply`), so the key of a binding is `SystemName:version` + role, e.g. `PowerSupply:0.current`.
  - A reference without a version (`"PowerSupply"`) is read as version 0. RFC-104 defines no version syntax, so this is the app's convention, borrowed from the schemas' `Name:version` references.
  - **Subsystems.** A subsystem is its own `systems` entry, so its modules are bound under the subsystem's own `Name:version` and role. When another entry names it as one of its roles (`mag5t` → `X` → `mag5t_x`), that outer system is recorded on the binding as a parent; no second binding is made. Entries that name no module and no local system are skipped.
- **System definitions in code.** A *system module* (one Elixir module per system schema, e.g. `PowerSupply`) names the schema, the versions it handles, and a *role module* for each role it customises (`current` → `PowerSupply.Current`). Config lists the system modules. This change ships no production system, only the mechanism and test systems. A role module declares:
  - the parameters the module must have;
  - an optional custom card: its body and the parameters it shows;
  - an optional custom plot.

  A module whose binding has a system module, a listed version and a role module, and which has all the role module's required parameters, gets that role module's card and plot. Everything else stays generic.
- **Custom cards.** On the dashboard a matched module with a card gets the role module's card body. The shared card chrome stays: the selection border, the status tint and edge, the dashed look while disconnected or paused, the header and the parameters button. The parameters a card shows get live updates, not only `value`, `target` and `status`.
- **Custom main module plot.** A role module's plot is one of two kinds:
  - **Lines plot:** one panel of number traces on up to two y-axes. A trace is one of the module's own parameters, or a path into one: a struct field, or an element of a numeric array of at most 100 elements. The element is picked by index, one trace per element, or by the value of its label (the element of a mass spectrum whose `_mass` is 28). Traces can be setpoints (held like `target`) or start hidden.
  - **Array plot:** today's array plot of one array parameter (time × index heatmap with its lines mode, or the latest reading for long arrays), with its index labelled, e.g. a mass spectrum's index shown as `m/z 28` from its `_mass` parameter.

  Labels are fixed text, or read when the plot loads from the latest reading of the module's own parameters, through an optional template such as `m/z {}`. Examples: an MFC group's `composition[i]` traces labelled with `gas_list[i]`, and a spectrum's indexes labelled from `_mass`. The plot replaces the generic module plot in the inspector, live and in the data browser, and its live updates, zooms and recording-gap breaks follow it. Without a plot the plot stays generic.
- **System membership in the inspector.** The module panel names the systems a module belongs to, its role in each, and any parent systems (e.g. "current in mag5t_x · PowerSupply:0, X of mag5t · VectorMagnet:0"), whether or not anything matched.

### Out of scope

- The dedicated system views of issue #123 (X–Y plots, cycle awareness, impedance plots). The system and role modules, and the card bodies, are kept free of dashboard-only assumptions so that those views can reuse them.
- Shipping production systems (`PowerSupply`, an MFC group or others). Each comes in its own change.
- Subplots (several panels in one module plot), and a callback that decorates the built chart (limit lines, shaded ranges, tick formatting). Both wait until a production system needs them.
- Checking that a node conforms to a system schema beyond the parameters a role module requires. That can later be done with the Python secop-checker, which already runs on every description. Fetching or parsing schema YAML at runtime is not planned.
- Declarative, runtime-loaded card layouts. System definitions are code and ship with a release.
- Plot traces from other modules of the same system, and custom plots of a single parameter (the inspector's per-parameter plot buttons stay generic).
- Custom sparklines. They may be added later as another optional part of a role module. Until then a custom card may include the generic sparkline of `value`/`target`.
- The acquisition card. An `AcquisitionController` and the channels it claims keep their acquisition card even when they are bound in a system.
- The module rail, the node header and the per-parameter rows of the inspector; they stay generic.

## Capabilities

### New Capabilities

- `system-bindings`: how a node's `systems` property is read into per-module bindings (system name, version, role, local system name, parent systems), including version defaults, subsystems and malformed entries.
- `system-module-cards`: how system and role modules are registered and matched to a module's binding, what a custom card replaces on the live dashboard, its fallback to the generic card, its live updates, and the system membership shown in the inspector.
- `system-module-plots`: how a role module's plot replaces the generic module plot, live and historical, and its fallback to the generic plot. A plot is either a lines plot (number traces into parameters, struct fields and array elements, with labels and up to two y-axes) or an array plot with labelled indexes.

### Modified Capabilities

None. `openspec/specs/` holds no archived capabilities yet, and no in-flight change covers the dashboard cards or the module plot's line set.

## Impact

- **New pure module** `SecantService.Systems`: bindings from a node's custom properties, accepting string keys (the stored record, which the dashboard and data browser both use) and atom keys, as `SecantService.Acquisition` does.
- **New web modules**:
  - the system-module and role-module behaviours;
  - a registry (`SecantServiceWeb.Systems`) reading `config :secant_service, :systems`;
  - small helper components for card bodies that build the routed component ids.
- **Dashboard**:
  - `DashboardLive` matches once per description and routes the shown parameters to their value displays;
  - `ModuleGrid` renders matched cards;
  - `ModuleDetail` shows membership and passes the matched plot to `HistoryDB`;
  - the node browser gets the custom plot through the shared `ModuleDetail`.
- **Plotting**:
  - `PlotDB` builds a custom plot from a plot spec: one window fetch per parameter, fanned out to its traces;
  - traces have stable series names, with display labels kept apart from them;
  - `HistoryDB` uses the plot's resolved traces for windows, overviews, ranges and the live filter;
  - `Scalar.timeseries_option` can build a second y-axis;
  - the array plot (`ArrayHeatmap`, `ArrayLatest`) carries index labels;
  - the chart hook shows display labels in the legend and tooltips, on the heatmap's and the latest-reading plot's index axes, and in the array lines mode.
- **No database migration**, no change to recording, node services or the supervision tree.
