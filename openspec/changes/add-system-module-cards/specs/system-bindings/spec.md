# Spec Delta

## Purpose

Reads the SECoP `systems` node property into bindings that say, for each module of a node, which systems it belongs to, under which versioned system name and in which role, and which systems contain those as subsystems, so that views can rely on the guarantees of the system's definition.

## ADDED Requirements

### Requirement: Bindings from the systems property
For each entry of a node's `systems` property, every pair in its `modules` mapping whose value names a module of the node SHALL give that module a binding with: the local system name (the entry's key), the system name, the system version, the role (the pair's key) and the entry's description. A node without a `systems` property SHALL have no bindings.

#### Scenario: Power supply on a node
- **WHEN** a node declares `"systems": {"mag5t_x": {"system": "PowerSupply:0", "description": "X axis", "modules": {"current": "magcur_x", "voltage": "magvolt_x"}}}` and has modules `magcur_x` and `magvolt_x`
- **THEN** `magcur_x` has the binding local system `mag5t_x`, system `PowerSupply`, version 0, role `current`, and `magvolt_x` the same binding with role `voltage`

#### Scenario: Node without systems
- **WHEN** a node's description has no `systems` property
- **THEN** none of its modules has a binding

### Requirement: Same bindings live and stored
Bindings SHALL be the same whether the node's description was just received from the node or loaded with a session from the database.

#### Scenario: Session opened in the data browser
- **WHEN** the session of the power supply node above is opened in the data browser after the node is gone
- **THEN** `magcur_x` has the same binding as it had on the live dashboard

### Requirement: System reference and version
The `system` value SHALL be read as a reference `Name:version`, where the version is written with digits only. A reference without a `:` SHALL be read as version 0. A `system` value that is not a string, has an empty name, or has anything other than digits after its last `:` SHALL make the whole entry give no bindings.

#### Scenario: Reference without a version
- **WHEN** a systems entry has `"system": "PowerSupply"`
- **THEN** its bindings have system `PowerSupply` and version 0

#### Scenario: Versioned reference
- **WHEN** a systems entry has `"system": "PowerSupply:2"`
- **THEN** its bindings have system `PowerSupply` and version 2

#### Scenario: Malformed versions
- **WHEN** systems entries have `"system": "PowerSupply:beta"`, `"PowerSupply:"`, `"PowerSupply:1.0"` and `"PowerSupply:-1"`
- **THEN** none of those entries gives bindings, and the node's other entries are read as usual

### Requirement: Subsystems
When a pair of an entry's `modules` mapping names another entry's local system name, that other entry SHALL be a subsystem of this one. Each binding made by the subsystem's own entry SHALL record, as its parents, the containing entry's local system name, system name, version and the role naming the subsystem, followed by that entry's own parents. A subsystem SHALL NOT give its modules a second binding. A chain that leads back to an entry already in it SHALL stop there.

#### Scenario: Power supply inside a vector magnet
- **WHEN** entry `mag5t_x` (`PowerSupply:0`) maps `current` to module `magcur_x`, and entry `mag5t` (`VectorMagnet:0`) maps role `X` to `mag5t_x`
- **THEN** `magcur_x` has one binding, role `current` of `mag5t_x` (`PowerSupply:0`), whose parents are role `X` of `mag5t` (`VectorMagnet:0`)

#### Scenario: Two levels of nesting
- **WHEN** entry `lab` (`Lab:0`) maps role `magnet` to `mag5t`, and `mag5t` maps `X` to `mag5t_x` as above
- **THEN** `magcur_x`'s binding has the parents `X` of `mag5t`, then `magnet` of `lab`

#### Scenario: Subsystem contained twice
- **WHEN** entries `mag5t` and `rig` both name `mag5t_x` as one of their roles
- **THEN** the parents of `mag5t_x`'s bindings come from `mag5t`, the containing entry first by local system name

#### Scenario: Cycle
- **WHEN** entry `a` maps role `inner` to `b`, and entry `b` maps role `outer` to `a`
- **THEN** reading the bindings ends, and each chain stops at the first entry it would revisit

### Requirement: Entries that bind nothing
A pair whose value names neither a module of the node nor another entry SHALL give no binding. Malformed entries, such as one without a `modules` mapping, SHALL give no bindings and SHALL NOT affect the node's other entries or the rest of the dashboard. When a value names both a module and a local system, which RFC-104 forbids, it SHALL be read as the module.

#### Scenario: Module missing from the node
- **WHEN** an entry maps role `power` to `magpow_x` and the node has neither such a module nor such an entry
- **THEN** no binding is made for `power`, and the entry's other roles are bound

#### Scenario: Entry without a modules mapping
- **WHEN** an entry has `"system": "PowerSupply:0"` and no `modules`
- **THEN** that entry gives no bindings and the dashboard renders as usual

### Requirement: A module in several systems
A module named in several systems entries SHALL have one binding per entry, ordered by local system name.

#### Scenario: Module shared by two systems
- **WHEN** module `magtemp` is role `T` of entry `mag5t` and role `T` of entry `cryo1`
- **THEN** `magtemp` has two bindings, `cryo1` first, then `mag5t`
