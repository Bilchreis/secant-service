# Spec Delta

## MODIFIED Requirements

### Requirement: Plots covered
Breaks SHALL be drawn in plots drawn as number lines and in plots of numeric arrays. Number lines are a number parameter plotted on its own and the number lines of a module plot (`value`, `target`, `_value_uncalibrated`, `_target_calibrated`). A numeric array (not a setpoint) is drawn as a heatmap or, in Lines mode, as one line per element. Enum and struct plots, setpoint arrays, and arrays drawn as their latest reading only SHALL be drawn exactly as today.

#### Scenario: Enum plot across a gap
- **WHEN** an enum parameter of a session with a gap is plotted
- **THEN** it is drawn exactly as today

#### Scenario: Struct with an array field across a gap
- **WHEN** a struct parameter with an array field, of a session with a gap, is plotted
- **THEN** it is drawn exactly as today

#### Scenario: Setpoint array on its own
- **WHEN** a `target` array parameter of a session with a gap is plotted on its own
- **THEN** it is drawn exactly as today

### Requirement: Fallback for sessions without spans
For a session without any span, a number line of a parameter named `value` SHALL be broken wherever two consecutive drawn points are further apart than five times the larger of the module's poll interval and the bucket width of that part of the plot, and at least 1 minute apart. One poll interval applies to the whole plot. It is judged on the line as drawn, after merging the overview and the zoomed detail. Live plots never use it: every session they show has spans. Array plots never use it.

#### Scenario: Old recording with a suspend
- **WHEN** a session recorded before spans existed has a `value` read every 2 seconds (`pollinterval` 2) with a 10-minute hole in its readings
- **THEN** the historical plot breaks the line over the hole

#### Scenario: Old recording of an array
- **WHEN** the same session has an array `value` with the same hole, and some readings with missing (NaN) elements
- **THEN** its heatmap and its element lines are drawn as today

## ADDED Requirements

### Requirement: Heatmap rows end at a gap
A heatmap row holds from its reading until the next reading, or on a live plot the last one until now. A row SHALL end at the start of the earliest gap its hold overlaps by at least the threshold a value line breaks with, or that is open (recording stopped). A row SHALL never end before its own reading, and never be drawn longer than it is today.

#### Scenario: Spectrum across a disconnect
- **WHEN** a 20-element array read every 10 seconds is plotted over 30 minutes with every reading, and the session has a 5-minute gap
- **THEN** the row of the last reading before the gap ends at the gap start, the gap is empty, and the rows resume with the first reading after it

#### Scenario: Readings stamped inside a gap
- **WHEN** readings stamped 2 and 4 minutes into a 5-minute gap are stored (a node clock offset)
- **THEN** their rows end at their own times, so nothing is painted across the gap

#### Scenario: Short gap before a long one
- **WHEN** a row's hold spans a 1-second gap and then a 10-minute gap
- **THEN** the row ends at the start of the 10-minute gap

#### Scenario: Short gap at a coarse zoom
- **WHEN** the session has a 30-second disconnect and the heatmap shows 3 days of thinned readings in 15-minute buckets
- **THEN** the rows are drawn without a hole there

#### Scenario: Live heatmap when the node disconnects
- **WHEN** a live heatmap is open and its node disconnects
- **THEN** within the next plot update the last row ends at the disconnect and no longer grows with the clock

### Requirement: Heatmap readout follows the drawn rows
Hovering a heatmap where a row was ended by a gap SHALL show no reading.

#### Scenario: Pointer over a gap
- **WHEN** the pointer is over the empty part of the heatmap inside a 5-minute gap
- **THEN** no readout is shown

### Requirement: Array element lines break at a gap
In Lines mode, each element's line SHALL break at a gap by the same rule as a value line: it ends at the gap start holding its last value, and draws nothing until its next drawn reading. A reading a break leaves on its own SHALL be shown with a marker.

#### Scenario: Lines mode across a disconnect
- **WHEN** the 20-element array of the spectrum scenario is shown in Lines mode
- **THEN** each of the 20 lines breaks at the 5-minute gap

#### Scenario: First reading after a reconnect
- **WHEN** a live array plot in Lines mode receives its first reading after a gap
- **THEN** that reading shows as a marker on each element line until the next reading joins it
