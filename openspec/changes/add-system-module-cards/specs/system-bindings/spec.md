# Spec Delta

## Purpose

Reads the SECoP `systems` node property into bindings that say, for each module of a node, which systems it belongs to, under which versioned system name and in which role, so that views can rely on the guarantees of the system's definition.

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
Bindings SHALL be the same whether they are read from a description just received from the node or from the description stored with a session in the database.

#### Scenario: Session opened in the data browser
- **WHEN** the session of the power supply node above is opened in the data browser after the node is gone
- **THEN** `magcur_x` has the same binding as it had on the live dashboard

### Requirement: System reference and version
The `system` value SHALL be read as a reference `Name:version`, with the version a non-negative integer. A reference without a version SHALL be read as version 0. A `system` value that is not a string, has an empty name or has a version that is not a non-negative integer SHALL make the whole entry give no bindings.

#### Scenario: Reference without a version
- **WHEN** a systems entry has `"system": "PowerSupply"`
- **THEN** its bindings have system `PowerSupply` and version 0

#### Scenario: Versioned reference
- **WHEN** a systems entry has `"system": "PowerSupply:2"`
- **THEN** its bindings have system `PowerSupply` and version 2

#### Scenario: Malformed version
- **WHEN** a systems entry has `"system": "PowerSupply:beta"`
- **THEN** that entry gives no bindings and the other entries are read as usual

### Requirement: Entries that bind no module
A pair of an entry's `modules` mapping whose value is not the name of a module of the node SHALL give no binding. That covers subsystems (the value names another local system) and missing modules. Malformed entries, such as one without a `modules` mapping, SHALL give no bindings and SHALL NOT affect the node's other entries or the rest of the dashboard.

#### Scenario: Subsystem
- **WHEN** an entry `mag5t` of system `VectorMagnet` maps role `X` to `mag5t_x`, the local name of another systems entry, and the node has no module named `mag5t_x`
- **THEN** no module gets a binding for role `X` of `mag5t`, and the bindings of `mag5t_x`'s own entry are unaffected

#### Scenario: Module missing from the node
- **WHEN** an entry maps role `power` to `magpow_x` and the node has no such module
- **THEN** no binding is made for `power`, and the entry's other roles are bound

### Requirement: A module in several systems
A module named in several systems entries SHALL have one binding per entry, ordered by local system name.

#### Scenario: Module shared by two systems
- **WHEN** module `magtemp` is role `T` of entry `mag5t` and role `T` of entry `cryo1`
- **THEN** `magtemp` has two bindings, `cryo1` first, then `mag5t`
