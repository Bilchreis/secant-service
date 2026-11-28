# Spec Delta

## Purpose

Lets the live dashboard show a tailored card for a module that plays a known role in a SECoP system, defined in code per system and role on the guarantees of the system's definition, while every other module keeps the generic card built from its self-description.

## ADDED Requirements

### Requirement: System and role definitions
A system definition SHALL name a system schema, the versions it handles and, per version, a role definition for each role it customises. A role definition SHALL name the parameters a module must have, and MAY give a card (a body and the parameters it shows) and a module plot, each independently. The available system definitions SHALL come from the application's configuration; with none configured, every module SHALL get the generic card and plot.

#### Scenario: No systems configured
- **WHEN** no system definitions are configured and a node binds `magcur_x` as `PowerSupply:0` role `current`
- **THEN** `magcur_x` is shown with the generic card and the generic module plot

### Requirement: Matching a role definition to a module
A module SHALL match a role definition when one of its bindings has a configured system definition's system name and one of its versions, that version has a role definition for the binding's role, and the module has every parameter the role definition requires. Names and roles SHALL be compared exactly. With several matching bindings, the first in binding order SHALL be used; with several system definitions for one name, the first in configuration order.

#### Scenario: Matching role
- **WHEN** a `PowerSupply` system definition handles version 0 with a role definition for `current` requiring `control_active`, and `magcur_x` is bound as `PowerSupply:0` role `current` and has `control_active`
- **THEN** `magcur_x` matches that role definition

#### Scenario: Version the system does not handle
- **WHEN** the same system definition is configured and `magcur_x` is bound as `PowerSupply:1` role `current`
- **THEN** `magcur_x` is shown with the generic card and plot

#### Scenario: Role without a definition
- **WHEN** the same system definition has no role definition for `resistance`, and `magres_x` is bound as `PowerSupply:0` role `resistance`
- **THEN** `magres_x` is shown with the generic card and plot

#### Scenario: Required parameter missing
- **WHEN** `magcur_x` is bound as `PowerSupply:0` role `current` but has no parameter `control_active`
- **THEN** `magcur_x` is shown with the generic card and plot and the dashboard keeps working

#### Scenario: Module bound twice
- **WHEN** `magtemp` is bound in `cryo1` and in `mag5t`, and both systems have a matching role definition
- **THEN** `magtemp` uses the role definition of its `cryo1` binding

#### Scenario: Module inside a subsystem
- **WHEN** `magcur_x` is role `current` of `mag5t_x` (`PowerSupply:0`), which is role `X` of `mag5t` (`VectorMagnet:0`), and only a `PowerSupply` system definition is configured
- **THEN** `magcur_x` matches the `PowerSupply` role definition for `current`

### Requirement: Card and plot are independent
A matched role definition's card SHALL be used only if it gives one, and its plot only if it gives one. Without a card, the module SHALL keep the generic card; without a plot, the generic module plot.

#### Scenario: Plot but no card
- **WHEN** a module matches a role definition that gives a plot and no card
- **THEN** the module has the generic card, with no system badge, and the custom module plot

#### Scenario: Card but no plot
- **WHEN** a module matches a role definition that gives a card and no plot
- **THEN** the module has the custom card and the generic module plot

### Requirement: What a custom card replaces
A custom card SHALL replace the body of a module's generic card in the card grid, in the module's place within its group. The card SHALL keep the generic card's id, the selection border, the status tint and edge, the dashed and faded look while the node is disconnected or paused, the module name and class in the header, and the button that opens the module's parameters.

#### Scenario: Selecting a custom card
- **WHEN** the user clicks the name on a custom card
- **THEN** the module is selected and the card gets the selection border, as a generic card does

#### Scenario: Node paused
- **WHEN** the node of a module with a custom card is paused
- **THEN** the custom card is drawn dashed and faded, as a generic card is

#### Scenario: Card body and badge
- **WHEN** a module is shown with a custom card
- **THEN** the card shows the role definition's body in place of the generic value, target, sparkline and command buttons, and its header carries a badge naming the system with version and the role it was matched for

### Requirement: Live values on a custom card
Every parameter a custom card declares it shows SHALL be updated live on the card, as `value` and `target` are on a generic card, and SHALL start with the node's current value when the card is first shown. A shown `value` or `target` SHALL get each reading once.

#### Scenario: Extra parameter updates live
- **WHEN** a custom card declares that it shows `control_active` and the node reports a new `control_active` value
- **THEN** the card shows the new value without a reload

#### Scenario: Current value on first render
- **WHEN** the dashboard is opened on a node whose `magcur_x` has `control_active` true
- **THEN** the custom card shows `control_active` true right away

#### Scenario: Shown value
- **WHEN** a custom card declares that it shows `value` and the node reports a new `value`
- **THEN** the card's value display gets that reading once

### Requirement: Acquisition modules keep their card
An `AcquisitionController` and the channels it claims SHALL keep the acquisition card, even when they match a role definition that gives a card.

#### Scenario: Bound acquisition channel
- **WHEN** a channel claimed by an `AcquisitionController` matches a role definition with a card
- **THEN** the channel is still shown as a tile inside the controller's acquisition card

### Requirement: Matching again on a new description
When a node's description changes, its modules SHALL be matched again against the new description's bindings.

#### Scenario: System added by a new description
- **WHEN** a node that declared no systems sends a new description that binds `magcur_x` as `PowerSupply:0` role `current`, and a matching role definition with a card is configured
- **THEN** `magcur_x` is shown with the custom card once the dashboard has the new description

### Requirement: System membership in the module panel
The module panel SHALL list each binding of the selected module, naming its role, its local system name, its system name with version, and its parent systems with their roles, whether or not anything matched. This SHALL hold on the live dashboard and in the data browser.

#### Scenario: Bound module selected
- **WHEN** the user selects `magcur_x`, bound as role `current` of `mag5t_x` (`PowerSupply:0`) inside role `X` of `mag5t` (`VectorMagnet:0`)
- **THEN** the module panel names role `current`, system `mag5t_x`, `PowerSupply:0`, and the parent `X` of `mag5t` (`VectorMagnet:0`)

#### Scenario: Unbound module selected
- **WHEN** the user selects a module without bindings
- **THEN** the module panel shows no system membership
