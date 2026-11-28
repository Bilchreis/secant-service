# Spec Delta

## Purpose

Lets a role definition of a SECoP system give the module plot of a matched module: one panel of number traces into the module's own parameters, struct fields and array elements, with labels and up to two y-axes, in place of the line set its interface class gives, on the live dashboard and in the data browser alike.

## ADDED Requirements

### Requirement: Plot of a role definition
A role definition's plot SHALL be one panel with an ordered list of traces and up to two y-axes, each axis with an optional name and unit. A trace SHALL name one of the module's parameters and optionally a path into its value (struct fields and array indices), or a path to an array to draw as one trace per element. It SHALL say whether it is a setpoint, starts hidden, and goes on the second axis.

#### Scenario: Role definition without a plot
- **WHEN** a module matches a role definition that gives no plot
- **THEN** its module plot draws the lines of its interface class, as today

### Requirement: Custom traces replace the interface-class lines
When the selected module matches a role definition with a plot, its module plot SHALL draw the plot's traces in their order, instead of the lines its interface class names, in the live inspector and in the data browser. A parameter's own plot, opened from its row, SHALL stay generic.

#### Scenario: Live module plot with custom traces
- **WHEN** the `current` role definition's plot has the traces `value`, `target` (setpoint) and `voltage_limit` (second axis), and the user selects the matched `magcur_x` on the dashboard
- **THEN** the module plot draws `value`, the dashed `target` and `voltage_limit` against a second y-axis

#### Scenario: Historical module plot
- **WHEN** the same session is opened in the data browser and `magcur_x` is selected
- **THEN** the module plot draws the same three traces from the stored readings

#### Scenario: Parameter plot stays generic
- **WHEN** the user plots `voltage_limit` from its parameter row
- **THEN** only `voltage_limit` is plotted, as today

### Requirement: Traces are number lines
A trace SHALL be drawn only when the module has its parameter and the parameter's declared type gives a number at the trace's path. Any other trace SHALL be left out. When no trace is left, the module plot SHALL be the generic one.

#### Scenario: Optional parameter missing
- **WHEN** the plot names a `power_limit` trace and the module has no such parameter
- **THEN** the plot draws the other traces without `power_limit`

#### Scenario: Path to a string
- **WHEN** a trace's path leads to a string field
- **THEN** that trace is left out

#### Scenario: Nothing drawable
- **WHEN** none of the plot's traces can be drawn
- **THEN** the module plot is the generic one

### Requirement: Traces into structs and arrays
A trace with a path SHALL draw, for each reading, the number at that path. A trace drawn per array element SHALL give one trace per element, as many as the array's declared maximum length or, without one, as its latest reading has. A plot SHALL draw at most 16 traces; traces beyond that SHALL be left out in order. Elements beyond a trace's count SHALL be ignored.

#### Scenario: MFC group composition
- **WHEN** a module's `value` is a struct of `composition` (array of 4 numbers, in %), `gas_list` (array of 4 strings) and `total_flow` (number, ml/min), and the plot draws `composition` per element and `total_flow` on the second axis
- **THEN** the plot draws four composition traces against the left axis and `total_flow` against the right one

#### Scenario: Long array
- **WHEN** a trace is drawn per element of an array declared with a maximum length of 200
- **THEN** the plot draws no more than 16 traces in all

### Requirement: Unreadable readings
A reading that has no number at a trace's path SHALL give that trace no point, and SHALL neither fail the plot nor the dashboard. That covers a missing field, a short array and a value the node reported as an error. Readings SHALL be read the same whether they arrived live or were loaded from the database.

#### Scenario: Short array reading
- **WHEN** a live reading of `composition` has 3 elements while the plot draws 4 composition traces
- **THEN** the fourth trace gets no point for that reading, and the dashboard keeps working

### Requirement: Trace labels
A trace's legend and tooltip label SHALL be fixed text, or SHALL be read from the latest reading when the plot loads: a path in the same parameter's value (for per-element traces, the element at the same index of an array) or a path in another parameter's value. Without a usable label (missing, empty or not a string), a trace SHALL be labelled by its parameter and path.

#### Scenario: Gas names
- **WHEN** the MFC group's latest `value` has `gas_list` `[N2, H2, CO, O2]` and the plot labels the composition traces from `gas_list`
- **THEN** the four composition traces are labelled N2, H2, CO and O2

#### Scenario: Label missing
- **WHEN** the latest reading's `gas_list` has only 3 entries
- **THEN** the fourth composition trace is labelled `value.composition[3]`

### Requirement: Labels are display only
Labels SHALL stay as loaded until the plot loads again. Labels SHALL NOT change how the plot's lines are identified, so equal labels or a changed label leave zooming, live updates and the legend's hidden lines intact.

#### Scenario: Equal labels
- **WHEN** two composition traces get the same gas name as their label
- **THEN** both are drawn, extended and hidden on their own

#### Scenario: Gas list changes during a live plot
- **WHEN** the node reports a `gas_list` with a different gas while the live plot is open
- **THEN** the traces keep their labels and keep extending, and the new label shows once the plot loads again

### Requirement: Setpoint and hidden traces
A trace marked as a setpoint SHALL be drawn and held like a module's `target` is today: a step line held from its last reading before the window, ending and resuming at recording gaps. A trace marked hidden SHALL start deselected in the legend.

#### Scenario: Setpoint held from before the window
- **WHEN** a trace marked as a setpoint last changed two hours before the shown window
- **THEN** it is drawn across the window at the value in force

#### Scenario: Hidden trace
- **WHEN** a trace is marked hidden
- **THEN** it is deselected in the legend when the plot opens

### Requirement: Second y-axis
Traces marked for the second axis SHALL be drawn against an axis on the right, and the others against the left axis. Each axis SHALL carry the name and unit the plot gives it, or else the unit of its first trace. Without any trace on the second axis, the plot SHALL have one y-axis, as today.

#### Scenario: Two units
- **WHEN** a plot draws `value` in A and `voltage_limit` in V on the second axis, and names no axes
- **THEN** the left axis is labelled A and the right axis V, and `voltage_limit` is drawn against the right axis

### Requirement: Recording gaps and bands
Every trace SHALL break at the session's recording gaps as the number lines of a module plot do. For a session recorded without spans, the gap estimate SHALL apply only to a trace that is the whole `value` parameter. In the data browser, an envelope band SHALL be drawn only for a trace that is a whole number parameter and not a setpoint.

#### Scenario: Trace across a gap
- **WHEN** the session has a recording gap inside the shown window
- **THEN** every trace of the custom plot is broken there

#### Scenario: Band on a whole parameter only
- **WHEN** a thinned historical custom plot draws a whole number parameter `pressure` and a `composition` element of `value`
- **THEN** only the `pressure` trace gets a band

### Requirement: Live updates and windows follow the traces
A live custom plot SHALL extend each trace with the readings of its parameter as they arrive, and SHALL ignore readings of parameters it does not draw. Zooming, panning, range changes and the overview SHALL load the same traces.

#### Scenario: Reading of a custom trace
- **WHEN** the live module plot draws `voltage_limit` and the node reports a new `voltage_limit` value
- **THEN** the `voltage_limit` trace is extended with it

#### Scenario: Zoom into a custom plot
- **WHEN** the user zooms into a historical custom plot
- **THEN** the zoomed window shows the same traces at finer detail

### Requirement: Modules without a custom plot
A module that matches no role definition with a plot SHALL get the module panel's plot or table exactly as today, including the table for a module whose `value` cannot be plotted.

#### Scenario: Module with a string value
- **WHEN** a module whose `value` is a string matches no role definition with a plot
- **THEN** the module panel shows its readings as a table, as today
