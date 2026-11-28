# Proposal

## Why

Everything on the live dashboard is built generically from a module's self-description: the card shows `value`, `target`, `status` and `stop`/`go`, and the module plot draws the lines its interface class names. A module that is part of a SECoP *system* (RFC-104, e.g. the proposed [`PowerSupply:0`](https://github.com/SampleEnvironment/SECoP/blob/master/schema/proposed/power_supply.yaml)) comes with a schema that guarantees more: which role it plays in the system and which extra parameters it has (a mass flow controller's gas type, a power supply's `control_active` and limits). The dashboard ignores that and can't show it. This change lets the app ship tailored cards and module plots for system modules, as a step towards the system views of issue #123.

## What Changes

- **Read a node's systems.** The node property `systems` (already stored in the node's custom properties) is read into *bindings*: for every module the systems it belongs to, as `{local system name, system name, version, role}`. The role is the module name the system definition gives it (`current` in `PowerSupply`), so the key of a binding is `SystemName:version` + `role`, e.g. `PowerSupply:0.current`. A reference without a version (`"PowerSupply"`) is read as version 0. Entries that name another local system (subsystems) and entries that name no module of the node are skipped.
- **Custom cards for system modules.** A custom card is an Elixir module implementing a new behaviour: the system it is for, the versions and roles it handles, the parameters the module must have, the parameters the card shows, and the card body as a function component. Cards are listed in application config; this change ships no production card, only the mechanism and a test card.
  - On the dashboard a module whose binding matches a card (system name, a listed version, a listed role, and all required parameters present) gets that card instead of the generic one. The shared card chrome stays: the selection border, the status tint and edge, the dashed look while disconnected or paused, the header and the parameters button.
  - Any other module, including one whose system or version no card handles or which lacks a required parameter, keeps the generic card.
  - The parameters a card declares get live updates, not only `value`, `target` and `status`.
- **Custom main module plot.** A card may also define the module plot: which of the module's own parameters are drawn, which are setpoints (held like `target`), which start hidden in the legend, and which go on a second y-axis. It replaces the interface-class line set in the inspector's module plot, live and in the data browser, and the plot's live updates follow the custom lines. Without a plot definition the plot stays generic.
- **System membership in the inspector.** The module panel names the systems a module belongs to and its role in each (e.g. "current in mag5t_x · PowerSupply:0"), whether or not a card matched.

### Out of scope

- The dedicated system views of issue #123 (X–Y plots, cycle awareness, impedance plots). Reusing custom cards there is planned for later; the behaviour is kept free of dashboard-only assumptions so that it can be.
- Shipping production cards (`PowerSupply`, a mass flow controller or others). Each comes in its own change.
- Fetching, parsing or validating system schema YAML at runtime, or checking that a node conforms to a system beyond the parameters a card requires.
- Declarative, runtime-loaded card layouts. Cards are code and ship with a release.
- Plot lines from other modules of the same system, and custom plots of a single parameter (the inspector's per-parameter plot buttons stay generic).
- Custom sparklines. A custom card may include the generic sparkline of `value`/`target`.
- The acquisition card. An `AcquisitionController` and the channels it claims keep their acquisition card even when they are bound in a system.
- The module rail, the node header and the per-parameter rows of the inspector; they stay generic.

## Capabilities

### New Capabilities

- `system-bindings`: how a node's `systems` property is read into per-module bindings (system name, version, role, local system name), including version defaults and malformed or subsystem entries.
- `system-module-cards`: how a custom card is registered and matched to a module's binding, what it replaces on the live dashboard, its fallback to the generic card, its live updates, and the system membership shown in the inspector.
- `system-module-plots`: how a card's plot definition replaces the interface-class lines of the module plot, live and historical, and its fallback to the generic plot.

### Modified Capabilities

None. `openspec/specs/` holds no archived capabilities yet, and no in-flight change covers the dashboard cards or the module plot's line set.

## Impact

- **New pure module** `SecantService.Systems` (bindings from a node's custom properties; atom keys from a fresh description, string keys from the database, as in `SecantService.Acquisition`).
- **New web modules**: the card behaviour, a registry (`SecantServiceWeb.SystemCards`) reading `config :secant_service, :system_cards`, and small helper components for card bodies that build the routed component ids.
- **Dashboard**: `ModuleGrid` renders matched cards; `DashboardLive` routes the declared card parameters to their value displays; `ModuleDetail` shows membership and passes a card's plot definition to `HistoryDB`. The node browser gets the custom plot through the shared `ModuleDetail`.
- **Plotting**: `PlotDB.lines` accepts a plot definition; `HistoryDB` resolves its lines once and uses them for the first load, windows, overviews, ranges and live filtering; `Scalar.timeseries_option` can build a second y-axis. The chart hook already handles `yAxis` lists and copies `yAxisIndex` to bands.
- **No database migration**, no change to recording, node services or the supervision tree.
