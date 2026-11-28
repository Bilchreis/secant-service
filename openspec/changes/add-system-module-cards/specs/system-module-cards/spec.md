# Spec Delta

## Purpose

Lets the live dashboard show a tailored card for a module that plays a known role in a SECoP system, built on the guarantees of the system's definition, while every other module keeps the generic card built from its self-description.

## ADDED Requirements

### Requirement: Card definitions
A custom card SHALL name the system it is for, the system versions and roles it handles, the parameters a module must have for it, and the parameters it shows. The set of available cards SHALL come from the application's configuration; with none configured, every module SHALL get the generic card.

#### Scenario: No cards configured
- **WHEN** no custom cards are configured and a node binds `magcur_x` as `PowerSupply:0` role `current`
- **THEN** `magcur_x` is shown with the generic card

### Requirement: Matching a card to a module
A module SHALL get a custom card when one of its bindings has the card's system name, one of its versions and one of its roles, and the module has every parameter the card requires. System names and roles SHALL be compared exactly. When several bindings or cards match, the first matching binding in binding order SHALL be used, with the first matching card in configuration order.

#### Scenario: Matching card
- **WHEN** a card is configured for system `PowerSupply`, versions [0], roles [`current`, `voltage`], requiring `control_active`, and `magcur_x` is bound as `PowerSupply:0` role `current` and has `control_active`
- **THEN** `magcur_x` is shown with that card

#### Scenario: Version the card does not handle
- **WHEN** the same card is configured and `magcur_x` is bound as `PowerSupply:1` role `current`
- **THEN** `magcur_x` is shown with the generic card

#### Scenario: Role the card does not handle
- **WHEN** the same card is configured and `magres_x` is bound as `PowerSupply:0` role `resistance`
- **THEN** `magres_x` is shown with the generic card

#### Scenario: Required parameter missing
- **WHEN** the same card is configured and `magcur_x` is bound as `PowerSupply:0` role `current` but has no parameter `control_active`
- **THEN** `magcur_x` is shown with the generic card and the dashboard keeps working

#### Scenario: Module bound twice
- **WHEN** `magtemp` is bound in `cryo1` and in `mag5t`, and cards are configured for both systems
- **THEN** `magtemp` is shown with the card of its `cryo1` binding

### Requirement: What a custom card replaces
A custom card SHALL replace the body of a module's generic card in the card grid, in the module's place within its group. The card SHALL keep the generic card's id, the selection border, the status tint and edge, the dashed and faded look while the node is disconnected or paused, the module name and class in the header, and the button that opens the module's parameters.

#### Scenario: Selecting a custom card
- **WHEN** the user clicks the name on a custom card
- **THEN** the module is selected and the card gets the selection border, as a generic card does

#### Scenario: Node paused
- **WHEN** the node of a module with a custom card is paused
- **THEN** the custom card is drawn dashed and faded, as a generic card is

#### Scenario: Card body
- **WHEN** a module is shown with a custom card
- **THEN** the card shows that card's body in place of the generic value, target, sparkline and command row, and shows which system and role it was matched for

### Requirement: Live values on a custom card
Every parameter a custom card declares it shows SHALL be updated live on the card, as `value` and `target` are on a generic card. A displayed parameter SHALL start with the node's current value when the card is first shown.

#### Scenario: Extra parameter updates live
- **WHEN** a custom card declares that it shows `control_active` and the node reports a new `control_active` value
- **THEN** the card shows the new value without a reload

#### Scenario: Current value on first render
- **WHEN** the dashboard is opened on a node whose `magcur_x` has `control_active` true
- **THEN** the custom card shows `control_active` true right away

### Requirement: Acquisition modules keep their card
An `AcquisitionController` and the channels it claims SHALL keep the acquisition card, even when they are bound in a system that a custom card matches.

#### Scenario: Bound acquisition channel
- **WHEN** a channel claimed by an `AcquisitionController` is bound in a system that a configured card matches
- **THEN** the channel is still shown as a tile inside the controller's acquisition card

### Requirement: A card from a newer description
When a node's description changes, the cards SHALL be matched again against the new description's bindings.

#### Scenario: System added by a new description
- **WHEN** a node that declared no systems sends a new description that binds `magcur_x` as `PowerSupply:0` role `current`, and a matching card is configured
- **THEN** `magcur_x` is shown with the custom card once the dashboard has the new description

### Requirement: System membership in the module panel
The module panel SHALL list each binding of the selected module, naming its role, its local system name and its system name with version, whether or not a custom card matched.

#### Scenario: Bound module selected
- **WHEN** the user selects `magcur_x`, bound as role `current` of `mag5t_x` (`PowerSupply:0`)
- **THEN** the module panel names role `current`, system `mag5t_x` and `PowerSupply:0`

#### Scenario: Unbound module selected
- **WHEN** the user selects a module without bindings
- **THEN** the module panel shows no system membership
