# Spec Delta

## Purpose

Lets historical line plots of long recordings show each bucket's spread and trend, as a shaded min–max band around a mean line read from the reading aggregates, with a toggle and a fallback to the plain plot when zoomed in.

## ADDED Requirements

### Requirement: Envelope of a number line
While the envelope is on and a historical plot's window is split into buckets of at least 1 minute, a number parameter's line SHALL be drawn per aggregated bucket as a shaded band from the bucket's min to its max and a line through its mean. This applies to a number parameter plotted on its own, to the `value` of a Readable, Acquisition or Drivable module, and to the `value` and `_value_uncalibrated` of a Calibratable module.

#### Scenario: Long recording of a double
- **WHEN** the historical plot of a `double` parameter shows 72 h of 1 Hz readings with the envelope on, and the aggregates are materialized for that time
- **THEN** each 15-minute bucket is drawn as a band from its min to its max with the line passing through its mean, and the plot loads no thinned readings for those buckets

#### Scenario: Drivable module
- **WHEN** a Drivable module whose `value` and `target` are doubles is plotted historically with the envelope on
- **THEN** `value` is drawn as an envelope wherever its window has aggregated buckets, and `target` is drawn as today's dashed step line with every point it has today, without a band, at every zoom

#### Scenario: Calibratable module
- **WHEN** a Calibratable module whose `value` is a double is plotted historically with the envelope on
- **THEN** `value` and `_value_uncalibrated` are each drawn as an envelope wherever their windows have aggregated buckets, `target` and `_target_calibrated` are drawn as today without a band, and hiding `_value_uncalibrated` in the legend hides its band too

#### Scenario: Setpoint opened on its own
- **WHEN** a `target` or `_target_calibrated` parameter is opened as a parameter plot on its own
- **THEN** it is drawn as today, and no envelope toggle is shown

#### Scenario: Plots without envelopes
- **WHEN** an enum parameter or a struct parameter is plotted historically
- **THEN** it is drawn exactly as today

### Requirement: Envelope of array plots in Lines mode
A numeric array plot of at most 100 elements (by its `maxlen`) in Lines mode SHALL draw one band and one mean line per element while the envelope is on, each in that element's line colour. In Heatmap mode the envelope SHALL have no effect.

#### Scenario: Array in Lines mode
- **WHEN** a 10-element `double` array is plotted historically in Lines mode with the envelope on, over a window with buckets of 1 minute or more whose aggregates are materialized
- **THEN** each element is drawn as a band and a mean line in its own colour

#### Scenario: Array that may outgrow the heatmap
- **WHEN** a numeric array whose `maxlen` is over 100 is plotted historically
- **THEN** it is drawn as today, and no envelope toggle is shown

#### Scenario: Array in Heatmap mode
- **WHEN** the same array is shown in Heatmap mode
- **THEN** the heatmap is drawn as today, and the envelope toggle is not shown

### Requirement: Fallback when zoomed in
When the requested window is shown with every reading, or with buckets narrower than 1 minute, the plot SHALL draw exactly what it draws without the envelope, with no band in that window.

#### Scenario: Zooming in past the finest tier
- **WHEN** a plot drawn as an envelope is zoomed in so that the requested window gets 30-second buckets
- **THEN** the zoomed window shows today's thinned line with no band, the rest of the time axis keeps its envelope, and no band is drawn across the zoomed window

#### Scenario: Every reading
- **WHEN** the requested window holds few enough readings to show every one
- **THEN** every reading is drawn as today, with no band

#### Scenario: Zooming back out
- **WHEN** the plot is zoomed back out to a window with buckets of 1 minute or more
- **THEN** the envelope is drawn again for that window

### Requirement: Readings outside the aggregated buckets
Readings in the part of a window before its first whole bucket, and after the last whole bucket that is both inside the window and materialized, SHALL be drawn as today's line for that window. The plot's time axis SHALL reach the window's first and last reading, as it does today.

#### Scenario: Newest minutes
- **WHEN** an envelope plot's window reaches past the point up to which the aggregates are materialized
- **THEN** the band ends at the last materialized bucket, and the readings after it are drawn as today's thinned or raw line, continuing the mean line

#### Scenario: Window edges between bucket boundaries
- **WHEN** a zoomed window starts and ends in the middle of a bucket
- **THEN** the band covers only the whole buckets inside the window, and the readings in the partial buckets at either edge are drawn as today's line

#### Scenario: Finished recording
- **WHEN** a recording whose aggregates are fully materialized is plotted zoomed out, including one whose first reading falls exactly on a bucket boundary
- **THEN** the time axis starts at the recording's first reading and ends at its last reading, and both ends can be zoomed into

#### Scenario: Aggregates still backfilling
- **WHEN** the aggregates are not yet materialized for any part of the window, for example right after a deploy
- **THEN** the whole window is drawn as today, with no band and with today's resolution label

### Requirement: Envelope toggle
Historical plots that have a line able to carry an envelope SHALL show a toggle that switches the envelope on and off. Switching SHALL redraw the whole plot, including a zoomed window, in the chosen mode, without reloading the page and keeping the zoom.

#### Scenario: Switching off while zoomed
- **WHEN** the user switches the envelope off on a zoomed plot that shows an envelope
- **THEN** both the zoomed window and the rest of the time axis are redrawn as today's line, and the zoom stays where it was

#### Scenario: Switching back on
- **WHEN** the user switches the envelope on again, then pans before the redraw finishes
- **THEN** the plot ends up showing the envelope for the window it is panned to

#### Scenario: Plot without envelope-capable lines
- **WHEN** a historical plot shows only an enum, a struct, a heatmap, or a live window
- **THEN** no envelope toggle is shown

### Requirement: Envelope defaults
The envelope SHALL be on by default for plots other than array plots, and off by default for array plots. A user's choice SHALL be remembered in the browser, separately for array plots and for other plots.

#### Scenario: First visit
- **WHEN** a user opens a historical plot of a `double` and one of a numeric array in Lines mode, never having used the toggle
- **THEN** the `double` plot shows an envelope and the array plot does not

#### Scenario: Remembered choice
- **WHEN** the user switches the envelope on for an array plot and later opens another array plot
- **THEN** the other array plot opens with the envelope on, and non-array plots keep their own setting

### Requirement: Envelope readout
While envelope buckets are shown, the plot's resolution label SHALL say that it shows min, mean and max per interval and name the envelope's interval width, and the tooltip SHALL give a bucket's min, mean and max.

#### Scenario: Resolution label
- **WHEN** a window is drawn as an envelope with 15-minute buckets
- **THEN** the label reads as min/mean/max per 15-minute interval, and changes to today's label when the plot falls back

#### Scenario: Tooltip on a bucket
- **WHEN** the pointer is over a bucket of an envelope
- **THEN** the tooltip shows that bucket's mean with its min and max for each line that has a band there, and lists each line once

### Requirement: Legend hides line and band together
In plots that have a legend, hiding a series in the legend SHALL hide its band together with its line, and the legend SHALL show one entry per line.

#### Scenario: Hiding value
- **WHEN** the user hides `value` in a Drivable plot's legend while the envelope is on
- **THEN** both the mean line and the band of `value` disappear, and they stay hidden after zooming
