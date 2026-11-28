# Spec Delta

## Purpose

Lets a role definition of a SECoP system give the module plot of a matched module, using the meaning its schema guarantees: number traces into the module's own parameters, struct fields and array elements with labels and up to two y-axes, or an array plot whose index is labelled (e.g. a mass spectrum by mass number), on the live dashboard and in the data browser alike.

## ADDED Requirements

### Requirement: Plot of a role definition
A role definition's plot SHALL be either a lines plot or an array plot. A lines plot SHALL be one panel with an ordered list of traces and up to two y-axes, each axis with an optional name and unit. An array plot SHALL draw the module's `value`, which must be a numeric array, and SHALL name a parameter of the module as the source of its index labels, and an optional index axis name. A role whose array plot cannot be drawn SHALL get the generic module plot.

#### Scenario: Role definition without a plot
- **WHEN** a module matches a role definition that gives no plot
- **THEN** its module plot is the generic one, as today

### Requirement: Custom plot replaces the generic module plot
When the selected module matches a role definition with a plot and has a `value` parameter, its module plot SHALL be the role's plot instead of the generic one, in the live inspector and in the data browser. A module without a `value` parameter SHALL keep today's panel. A parameter's own plot, opened from its row, SHALL stay generic.

#### Scenario: Live lines plot
- **WHEN** the `current` role definition's lines plot has the traces `value`, `target` (setpoint) and `voltage_limit` (second axis), and the user selects the matched `magcur_x` on the dashboard
- **THEN** the module plot draws `value`, the dashed `target` and `voltage_limit` against a second y-axis

#### Scenario: Historical lines plot
- **WHEN** the same session is opened in the data browser and `magcur_x` is selected
- **THEN** the module plot draws the same three traces from the stored readings

#### Scenario: Parameter plot stays generic
- **WHEN** the user plots `voltage_limit` from its parameter row
- **THEN** only `voltage_limit` is plotted, as today

### Requirement: Traces
A trace SHALL name one of the module's parameters and optionally a path through struct fields to a number (`double`, `int` or `scaled`; enums are not traces), or to a numeric array of at most 100 elements. A trace into such an array SHALL pick one element: by index, one trace per element, or the element whose index-label value equals a given number. A trace SHALL say whether it is a setpoint, starts hidden, and goes on the second axis.

#### Scenario: Element picked by mass
- **WHEN** a trace picks the element of the mass spectrometer's `value` whose `_mass` value is 28, and the latest `_mass` reading has 28.0 at index 27
- **THEN** the trace draws element 27 of each `value` reading

#### Scenario: Mass not found
- **WHEN** a trace picks the element whose `_mass` value is 29 and the latest `_mass` reading has no 29
- **THEN** that trace is left out

### Requirement: Traces that cannot be drawn
A trace SHALL be left out when its parameter is missing, when its path does not lead through struct fields to a number or to a numeric array element, or when its array is declared or read with more than 100 elements. A lines plot SHALL draw at most 16 traces; traces beyond that SHALL be left out in order. When no trace is left, the module plot SHALL be the generic one.

#### Scenario: Optional parameter missing
- **WHEN** the plot names a `power_limit` trace and the module has no such parameter
- **THEN** the plot draws the other traces without `power_limit`

#### Scenario: Path to a string
- **WHEN** a trace's path leads to a string field
- **THEN** that trace is left out

#### Scenario: Long array
- **WHEN** a trace draws one trace per element of an array declared with a maximum length of 350 000
- **THEN** those traces are left out, and the plot reads none of that array's readings for them

#### Scenario: Nothing drawable
- **WHEN** none of the plot's traces can be drawn
- **THEN** the module plot is the generic one

### Requirement: One trace per element
A trace drawn per element SHALL give one trace per element up to the array's declared maximum length or, without one, the length of the latest reading, and never more than the traces left under the cap. Elements beyond a trace's count SHALL be ignored.

#### Scenario: MFC group composition
- **WHEN** a module's `value` is a struct of `composition` (array of 4 numbers, in %), `gas_list` (array of 4 strings) and `total_flow` (number, ml/min), and the plot draws `composition` per element and `total_flow` on the second axis
- **THEN** the plot draws four composition traces against the left axis and `total_flow` against the right one

### Requirement: Unreadable readings
A reading that has no number where a trace reads SHALL give that trace no point, and SHALL neither fail the plot nor the dashboard. That covers a missing field, a short array and a value the node reported as an error. Readings SHALL be read the same whether they arrived live or were loaded from the database.

#### Scenario: Short array reading
- **WHEN** a live reading of `composition` has 3 elements while the plot draws 4 composition traces
- **THEN** the fourth trace gets no point for that reading, and the dashboard keeps working

### Requirement: Label sources
A trace label or an array plot's index labels SHALL come from fixed text or from a label source: a path in the latest reading of the trace's own parameter or of another parameter of the module, read when the plot loads. For per-element traces and index labels, the source SHALL be an array read at the same index.

#### Scenario: Gas names from the same value
- **WHEN** the MFC group's latest `value` has `gas_list` `[N2, H2, CO, O2]` and the plot labels the composition traces from `gas_list`
- **THEN** the four composition traces are labelled N2, H2, CO and O2

#### Scenario: Labels from another parameter
- **WHEN** a per-element trace of the mass spectrometer's `value` takes its labels from `_mass` with the template `m/z {}`, and the latest `_mass` is `[1.0, 2.0, 3.0]`
- **THEN** the traces are labelled `m/z 1`, `m/z 2` and `m/z 3`

### Requirement: Label text
A label source that gives a string SHALL be used as it is, and one that gives a number SHALL be written without a fractional part when it is whole, else in its shortest form. A template SHALL put that text in place of `{}`. Without a usable value (missing, empty, neither string nor number, or no reading yet), a trace SHALL be labelled by its parameter and path, e.g. `value.composition[2]`, and an index by its number. Labels SHALL be shown as text, never as markup.

#### Scenario: Label missing
- **WHEN** the latest reading's `gas_list` has only 3 entries
- **THEN** the fourth composition trace is labelled `value.composition[3]`

#### Scenario: Label with markup
- **WHEN** the latest `gas_list` holds the string `<b>N2</b>`
- **THEN** the legend and tooltip show the literal text `<b>N2</b>`

### Requirement: Labels are display only
Labels, and elements picked by label value, SHALL stay as loaded until the plot loads again. Labels SHALL NOT change how the plot's lines are identified, so equal labels or a changed label leave zooming, live updates and the legend's hidden lines intact.

#### Scenario: Equal labels
- **WHEN** two composition traces get the same gas name as their label
- **THEN** both are drawn, extended and hidden on their own

#### Scenario: Mass table changes during a live plot
- **WHEN** the node reports a new `_mass` while a live plot labelled from it is open
- **THEN** the plot keeps its labels and picked elements and keeps extending, and the new ones apply once the plot loads again

### Requirement: Array plot with index labels
An array plot SHALL draw `value` as the generic array plot does (a time × index heatmap with its lines mode, or the latest reading for arrays too long for the heatmap). Each index SHALL be shown by its label on the heatmap's index axis and hover readout, and in the lines-mode tooltip, for as many indexes as the label source has entries, up to 100. The index axis SHALL carry the plot's index axis name, if given.

#### Scenario: Mass spectrum heatmap
- **WHEN** the mass spectrometer's role plot is an array plot labelled from `_mass` with the template `m/z {}` and the axis name `m/z`
- **THEN** the heatmap's index axis shows `m/z 1`, `m/z 2`, … in place of 0, 1, …, and in lines mode the tooltip names each element's mass

#### Scenario: Fewer labels than elements
- **WHEN** `_mass` has 90 entries and `value` 100
- **THEN** indexes 90 to 99 are shown by their numbers

#### Scenario: Array grows live
- **WHEN** a labelled heatmap loads with 3 elements and `_mass` has 10 entries, and later readings have 10 elements
- **THEN** the new rows are labelled too

### Requirement: Latest-reading plot with index labels
When `value` is too long for the heatmap, its latest-reading plot SHALL show index labels on its index axis and in its tooltip when the label source has at most 4000 entries, and index numbers otherwise. When a labelled heatmap is rebuilt as a latest-reading plot because a reading got too long, the label source SHALL be read again.

#### Scenario: Spectrum that fills up
- **WHEN** a labelled heatmap of 3 elements is rebuilt as a latest-reading plot because a reading has 3000 elements, and the label source now has 3000 entries
- **THEN** the latest-reading plot shows all 3000 labels

#### Scenario: Very long spectrum
- **WHEN** the latest-reading plot draws a reading of 10 000 elements and the label source has 10 000 entries
- **THEN** the plot shows index numbers

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
Every trace of a lines plot SHALL break at the session's recording gaps as the number lines of a module plot do, and a live lines plot SHALL break when recording stops. For a session recorded without spans, the gap estimate SHALL apply only to a trace that is the whole `value` parameter. In the data browser, an envelope band SHALL be drawn only for a trace that is a whole number parameter and not a setpoint. An array plot SHALL show gaps and bands as the generic array plot does.

#### Scenario: Trace across a gap
- **WHEN** the session has a recording gap inside the shown window
- **THEN** every trace of the lines plot is broken there

#### Scenario: Session without spans
- **WHEN** a session recorded before recording spans existed is plotted with a whole `value` trace, a `value.composition[2]` trace and a `value[27]` trace
- **THEN** only the whole `value` trace gets the estimated gaps

#### Scenario: Band on a whole parameter only
- **WHEN** a thinned historical lines plot draws a whole number parameter `pressure` and a `composition` element of `value`
- **THEN** only the `pressure` trace gets a band

### Requirement: Live updates and windows follow the plot
A live custom plot SHALL extend each trace with the readings of its parameter as they arrive, and SHALL ignore readings of parameters it does not draw. Zooming, panning, range changes and the overview SHALL load the same traces, labels and picked elements.

#### Scenario: Reading of a custom trace
- **WHEN** the live module plot draws `voltage_limit` and the node reports a new `voltage_limit` value
- **THEN** the `voltage_limit` trace is extended with it

#### Scenario: Zoom into a custom plot
- **WHEN** the user zooms into a historical custom lines plot
- **THEN** the zoomed window shows the same traces at finer detail

### Requirement: Falling back when nothing resolves
When a lines plot passes the description check but no trace is left once the plot loads (a mass not found, an array read longer than 100 elements), the module plot SHALL be the generic one, and a module whose `value` cannot be plotted SHALL show its table, never an empty chart.

#### Scenario: Every trace dropped at load
- **WHEN** the only trace of a role's lines plot picks the element of `spectrum` whose `_mass` is 29, the latest `_mass` has no 29, and `value` is a string
- **THEN** the module panel shows the readings table, as for a module with no custom plot

### Requirement: Modules without a custom plot
A module that matches no role definition with a plot SHALL get the module panel's plot or table exactly as today, including the table for a module whose `value` cannot be plotted.

#### Scenario: Module with a string value
- **WHEN** a module whose `value` is a string matches no role definition with a plot
- **THEN** the module panel shows its readings as a table, as today
