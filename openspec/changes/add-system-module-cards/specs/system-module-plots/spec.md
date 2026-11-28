# Spec Delta

## Purpose

Lets a custom card for a system module define which of the module's parameters the module plot draws and how, in place of the line set its interface class gives, on the live dashboard and in the data browser alike.

## ADDED Requirements

### Requirement: Plot definition of a card
A custom card MAY define a module plot as an ordered list of lines, each naming one of the module's parameters and saying whether it is a setpoint, whether it starts hidden in the legend, and whether it is drawn on a second y-axis. The first line SHALL be the plot's primary line.

#### Scenario: Card without a plot definition
- **WHEN** a module is shown with a custom card that defines no plot
- **THEN** its module plot draws the lines of its interface class, as today

### Requirement: Custom lines replace the interface-class lines
When the selected module matches a card with a plot definition, its module plot SHALL draw the defined lines in their order, instead of the lines its interface class names. This SHALL hold in the inspector of the live dashboard and in the data browser. A parameter's own plot, opened from its row, SHALL stay generic.

#### Scenario: Live module plot with custom lines
- **WHEN** a card for `PowerSupply:0` role `current` defines the lines `value`, `target` (setpoint) and `voltage_limit` (second y-axis), and the user selects the matched `magcur_x` on the dashboard
- **THEN** the module plot draws `value`, the dashed `target` and `voltage_limit` against a second y-axis

#### Scenario: Historical module plot
- **WHEN** the same session is opened in the data browser and `magcur_x` is selected
- **THEN** the module plot draws the same three lines from the stored readings

#### Scenario: Parameter plot stays generic
- **WHEN** the user plots `voltage_limit` from its parameter row
- **THEN** only `voltage_limit` is plotted, as today

### Requirement: Lines the module cannot draw
A defined line SHALL be left out when the module has no such parameter or the parameter does not hold values a plot draws. When the primary line is left out, the module plot SHALL fall back to the lines of the module's interface class.

#### Scenario: Optional parameter missing
- **WHEN** the plot definition names `power_limit` and the module has no such parameter
- **THEN** the plot draws the other defined lines without `power_limit`

#### Scenario: Primary line not drawable
- **WHEN** the plot definition's first line is a parameter of type string
- **THEN** the module plot draws the lines of the module's interface class

### Requirement: Setpoint and hidden lines
A line marked as a setpoint SHALL be drawn and held like a module's `target` is today: as a step line held from its last reading before the window, ending and resuming at recording gaps. A line marked hidden SHALL start deselected in the legend and SHALL be shown when the user selects it there.

#### Scenario: Setpoint held from before the window
- **WHEN** a line marked as a setpoint last changed two hours before the shown window
- **THEN** it is drawn across the window at the value in force

#### Scenario: Hidden line
- **WHEN** a line is marked hidden
- **THEN** it is deselected in the legend when the plot opens and drawn once the user selects it

### Requirement: Second y-axis
Number lines marked for the second y-axis SHALL be drawn against an axis on the right, labelled with the unit of the first such line; the other lines SHALL use the left axis, labelled with the primary line's unit. Without any line marked for it, the plot SHALL have one y-axis, as today.

#### Scenario: Two units
- **WHEN** a plot defines `value` in A and `voltage_limit` in V on the second axis
- **THEN** the left axis is labelled A and the right axis V, and `voltage_limit` scales against the right axis

### Requirement: Plots other than number lines
When the primary line's values are drawn as enum bands, struct rows or an array plot, the module plot SHALL draw it as it would draw a module's `value` of that type, with at most one setpoint line where that drawing supports one; other defined lines and the second y-axis SHALL be ignored.

#### Scenario: Enum primary line
- **WHEN** a plot definition's primary line is an enum parameter, followed by a number line
- **THEN** the plot shows the enum's state bands only

### Requirement: Live updates follow the custom lines
A live module plot with custom lines SHALL extend each drawn line with the readings of its parameter as they arrive, and SHALL ignore readings of parameters it does not draw. Zooming, panning and range changes SHALL load the same lines.

#### Scenario: Reading of a custom line
- **WHEN** the live module plot draws `voltage_limit` and the node reports a new `voltage_limit` value
- **THEN** the `voltage_limit` line is extended with it

#### Scenario: Zoom into a custom plot
- **WHEN** the user zooms into a historical module plot with custom lines
- **THEN** the zoomed window shows the same lines at finer detail
