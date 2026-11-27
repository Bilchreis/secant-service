# Spec Delta

## Purpose

Makes the number line plots show time in which a session was not recorded as a break in the line, instead of a straight line joining the readings on either side, in the historical and live plots alike.

## ADDED Requirements

### Requirement: Gaps of a session
For a session with recording spans, a gap SHALL be any time after its first span started that no span covers. That includes the time after its last span ended. An open span whose last-alive time is more than 45 seconds old SHALL count as ending at its last-alive time. Time before a session's first span is no gap. A session without any span has gaps only as the fallback requirement below derives them.

#### Scenario: Suspend inside a session
- **WHEN** a session has a span from 08:00 to 08:59:50 and the next from 09:12 on, still open and alive
- **THEN** its only gap runs from 08:59:50 to 09:12

#### Scenario: Server killed and not yet restarted
- **WHEN** a session's only span is still open and its last-alive time is 10 minutes old
- **THEN** the time from that last-alive time to now is a gap

### Requirement: Plots covered
Breaks SHALL be drawn in plots drawn as number lines: a number parameter plotted on its own, and the number lines of a module plot (`value`, `target`, `_value_uncalibrated`, `_target_calibrated`). Enum, struct and array plots SHALL be drawn exactly as today.

#### Scenario: Enum plot across a gap
- **WHEN** an enum parameter of a session with a gap is plotted
- **THEN** it is drawn exactly as today

### Requirement: Number lines break at a gap
A line SHALL be broken where a gap lies between two consecutive drawn points. It SHALL end at the gap start, holding the last point's value up to it, and SHALL draw nothing until the first point after the gap. For lines other than setpoints, two gaps between the same two points SHALL give one break.

#### Scenario: Value across a suspend, raw window
- **WHEN** the historical plot of a `double` value read every second shows a window of 30 minutes with every reading, and a 10-minute gap lies inside it
- **THEN** the line ends at the gap start, nothing is drawn for those 10 minutes, and the line resumes at the first reading after the gap

#### Scenario: Thinned window
- **WHEN** the same value is plotted over 3 days, thinned into 15-minute buckets, and the session has a 2-hour gap
- **THEN** the line has a break for that gap, and the points on either side are drawn as today

#### Scenario: No gap
- **WHEN** a window holds no gap
- **THEN** the plot is drawn exactly as today

### Requirement: Setpoint lines end and resume at a gap
A setpoint (step) line SHALL end at the gap start with the value in force, and SHALL resume at the gap end with the value in force there. Setpoints are only stored when they change, so that value may come from a reading before the gap. This SHALL hold for every gap, also several between two readings. A setpoint SHALL NOT be drawn inside a gap, nor on past a gap that has no later span; a setpoint reading stamped inside a gap takes effect at the gap end.

#### Scenario: Target unchanged across a gap
- **WHEN** a Drivable's `target` was set to 50 at 08:00, never changed, and the session has a gap from 09:00 to 09:10
- **THEN** the dashed target line runs at 50 up to 09:00, is not drawn from 09:00 to 09:10, and runs at 50 again from 09:10

#### Scenario: Target unchanged across two gaps
- **WHEN** the same `target` stays at 50 and the session has gaps from 09:00 to 09:10 and from 11:00 to 11:30
- **THEN** the target line is drawn at 50 outside both gaps and not inside either

#### Scenario: Setpoint reading stamped inside the gap
- **WHEN** a gap runs from 09:00:00 to 09:10:00 and a `target` reading of 60 is stamped 09:09:57
- **THEN** the target line is not drawn from 09:00:00 to 09:10:00, and runs at 60 from 09:10:00

#### Scenario: Zoomed into the gap
- **WHEN** that plot is zoomed to 09:02–09:08
- **THEN** no target line is drawn in the window

#### Scenario: Session that ended
- **WHEN** an archived session's last span ended at 12:00 and its `value` has readings until 12:00
- **THEN** its `target` line is not drawn past 12:00

### Requirement: A gap never hides a reading
Node timestamps and span times come from different clocks, so a reading can lie inside a gap. A stored reading inside a gap SHALL still be drawn, and each gap SHALL break a line at most once. Setpoints follow the setpoint requirement instead. The break goes between the two consecutive points whose time between them overlaps the gap the most. Placement is best effort when the node's clock is off by more than the gap's length.

#### Scenario: Node clock a few seconds behind
- **WHEN** a gap runs from 09:00:00 to 09:10:00 and the first `value` reading after it is stamped 09:09:57, because the node's clock runs a few seconds behind
- **THEN** the line breaks once, between the last reading before the gap and the reading at 09:09:57, and that reading is drawn with the line that follows it

### Requirement: Only breaks a line would visibly bridge
A break SHALL only be drawn where the two points it separates are at least 2 seconds apart within the gap, and, in a part of the plot drawn from thinned readings or envelopes, at least that part's bucket width apart. All lines of a plot SHALL use the same bucket width there: the coarsest of its lines. A gap that reaches into a finer part (a zoomed detail) SHALL use the finer part's width.

#### Scenario: Short disconnect at a coarse zoom
- **WHEN** a session has a 30-second disconnect and its plot shows 3 days in 15-minute buckets
- **THEN** neither the value nor the target line breaks there, and zooming in to a window with every reading shows the break on both

#### Scenario: Readings continue through a recorded gap
- **WHEN** a gap of 20 seconds was recorded but readings 1 second apart were stored throughout it
- **THEN** the line is drawn without a break

### Requirement: Envelope bands break at a gap
Where an envelope window's mean line breaks at a gap, its min–max band SHALL break too, without a band drawn across the gap.

#### Scenario: Envelope across an outage
- **WHEN** a value is drawn as an envelope in 1-hour buckets and the session has a 6-hour gap
- **THEN** both the mean line and the band end before the gap and start again after it

### Requirement: Breaks in every load of a plot
The breaks SHALL be the same however the plot's data was loaded and combined: the first load of a historical plot, a zoomed or panned window shown inside the overview, the overview reloaded after the envelope is switched on or off, and the first load and widened ranges of a live plot, including where the loaded parts meet.

#### Scenario: Zoomed window inside a gap
- **WHEN** a historical plot with a 6-hour gap is zoomed to a window lying entirely inside it
- **THEN** no line is drawn in the window, and zooming out shows the break with the overview on either side unjoined

#### Scenario: Widening a live plot over an old gap
- **WHEN** a live plot is widened from 10 minutes to all, and the older range holds a gap that ends just where the live buffer begins
- **THEN** the lines break at that gap

#### Scenario: Live plot opened after an outage
- **WHEN** a live plot is opened on a node that was disconnected for 5 minutes, 3 minutes ago, with the 10-minute range
- **THEN** its lines show a break for those 5 minutes

### Requirement: Open live plots break when recording stops
When recording of a node stops (disconnect, deactivation, host suspend, its services stopping), the live plots open on that node SHALL treat the time from then on as a gap. Readings received before it SHALL stay before the break. When recording resumes, setpoint lines SHALL resume with the value in force, and value lines with the next reading.

#### Scenario: Node disconnects while watched
- **WHEN** a live plot of a Drivable is open and its node disconnects
- **THEN** within the next plot update its `value` line ends at its last reading before the disconnect, its `target` line ends at the disconnect, and the `target` line no longer moves on with the clock

#### Scenario: Node comes back
- **WHEN** the node of that plot reconnects 2 minutes later
- **THEN** the `target` line resumes at the reconnect with the value in force, and `value` resumes with its next reading, with nothing drawn between

#### Scenario: Dashboard open through a suspend
- **WHEN** the dashboard is open in a browser on the suspended host itself, and after the resume the suspend is noticed only after the first new readings are drawn
- **THEN** the lines break over the suspend, and the new readings stay drawn after the break

### Requirement: Fallback for sessions without spans
For a session without any span, a line of a parameter named `value` SHALL be broken wherever two consecutive drawn points are further apart than five times the larger of the module's poll interval and the bucket width of that part of the plot, and at least 1 minute apart. One poll interval applies to the whole plot. It is judged on the line as drawn, after merging the overview and the zoomed detail. Live plots never use it: every session they show has spans.

#### Scenario: Old recording with a suspend
- **WHEN** a session recorded before spans existed has a `value` read every 2 seconds (`pollinterval` 2) with a 10-minute hole in its readings
- **THEN** the historical plot breaks the line over the hole

### Requirement: Fallback only where a poll interval is known
The fallback SHALL use the module's last `pollinterval` reading of the session. It SHALL NOT break parameters with any other name (setpoints included), nor the `value` of a module without a `pollinterval` reading.

#### Scenario: Old recording, change-only setpoint
- **WHEN** the same session's `target` has readings 3 hours apart
- **THEN** the target line holds between them without a break

#### Scenario: Module without a poll interval
- **WHEN** a span-less session's module has no `pollinterval` parameter and its `value` has a 10-minute hole
- **THEN** the line joins across the hole as today

### Requirement: Change-only parameters plotted on their own
A number parameter that is not a setpoint and is only sent when it changes (a `ramp`, say), plotted on its own, SHALL break at a gap like any value line. It is then drawn again from its next reading, even when that comes much later.

#### Scenario: Ramp across a gap
- **WHEN** a `ramp` parameter last changed at 08:00 and the session has a gap from 09:00 to 09:10
- **THEN** its line ends at 09:00 and is drawn again from its next reading
