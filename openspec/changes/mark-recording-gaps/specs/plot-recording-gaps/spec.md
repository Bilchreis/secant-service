# Spec Delta

## MODIFIED Requirements

### Requirement: Heatmap readout follows the drawn rows
Hovering a heatmap where a row was ended by a gap SHALL show no reading. Where that place lies in a marked region, the readout SHALL describe the gap instead (see "Hovering a region describes the gap"). Elsewhere it SHALL show nothing.

#### Scenario: Pointer over a gap
- **WHEN** the pointer is over the empty part of the heatmap inside a marked 5-minute gap
- **THEN** no reading is shown, and the readout describes the gap

## ADDED Requirements

### Requirement: Gaps are marked with a region
In a plot that breaks at gaps (see "Plots covered"), each marked gap SHALL be shown as a faint, neutral shaded region across the full height of the plot area, behind the data. It SHALL have a thin dashed line at its start and, for a gap that has ended, at its end. A region SHALL be clipped to the plot area, SHALL stay readable in the light and dark themes, and SHALL NOT appear in the legend.

#### Scenario: Node disconnected for 8 seconds
- **WHEN** a module plot of `value` and `target`, read every second, shows a session whose node was disconnected from 08:30:20 to 08:30:28
- **THEN** a shaded region with dashed edges spans 08:30:20 to 08:30:28 over the whole plot height, behind both lines, and both lines break there as before

#### Scenario: Heatmap and Lines mode across a gap
- **WHEN** a numeric array plot over a 5-minute gap is shown as a heatmap, and then in Lines mode
- **THEN** both show the region over the gap

#### Scenario: Zoomed into a gap
- **WHEN** a history plot is zoomed to a window lying wholly inside a marked gap
- **THEN** the whole plot area is shaded

### Requirement: Only gaps the plot shows are marked
A gap SHALL be marked while the plot shows it, at the current zoom, in any of these ways:
- it lies where a drawn line is broken and is wide enough to break a line there;
- it ends a heatmap row, or lies where a row was ended and is wide enough to end one;
- no reading of the plot follows it yet, which always includes an open gap (recording has not resumed);
- no reading of the plot comes before it.

Readings are the recorded readings the plot holds, not points added for drawing. Lines hidden through the legend count as drawn. Breaks made by the fallback for sessions without spans SHALL NOT be marked.

#### Scenario: Short gap at a coarse zoom
- **WHEN** the session has a 30-second disconnect and the plot shows 3 days of readings thinned into 15-minute buckets
- **THEN** the line is drawn without a break there and no region is shown

#### Scenario: Zooming in on it
- **WHEN** the user zooms into that hour until the readings are no longer thinned
- **THEN** the line breaks over the disconnect and its region appears

#### Scenario: Two gaps between the same readings
- **WHEN** a 2-minute and a 5-minute gap both lie between the same two consecutive readings
- **THEN** both are marked

#### Scenario: Gap reaching past the left edge of a live plot
- **WHEN** a live value plot showing the last 10 minutes is opened while its node has been disconnected since 11 minutes ago, and the node reconnects a minute later
- **THEN** the region is shown from the left edge to the reconnect, although no reading before the outage is in the window

#### Scenario: Old recording without spans
- **WHEN** a session recorded before spans existed is plotted and its `value` line breaks by the fallback
- **THEN** no region is shown

### Requirement: Ongoing gaps run to the plot's edge
A region of an open gap SHALL run from the gap start to the right edge of the plot area, as far as the time axis reaches, and SHALL have no end line. On a live plot it SHALL keep reaching the right edge as the plot moves on, including while no readings arrive. When recording resumes, the region SHALL end at the resume, and it SHALL stay shown while the plot's next reading has not arrived.

#### Scenario: Node disconnects while watched
- **WHEN** a live plot showing the last 10 minutes is open and its node disconnects
- **THEN** within the next plot update a region starts at the disconnect and runs to the right edge, and it still reaches the right edge a minute later, with no new readings

#### Scenario: Node comes back
- **WHEN** the node reconnects 2 minutes later
- **THEN** the region ends at the reconnect with a dashed end line, and stays shown until and after the next reading is drawn

### Requirement: Hovering a region describes the gap
With the pointer inside a marked region, the plot SHALL show a readout describing the gap instead of the readings. It SHALL contain:
- "Not recorded";
- the reason recording ended before the gap;
- the start;
- the end, or "ongoing";
- the duration so far.

On a heatmap, a drawn cell under the pointer SHALL show its reading as today. Outside regions, the plot's readout SHALL be the same as without regions. The readout SHALL follow a region that moves or closes under a resting pointer with the next redraw of the plot, including the redraws that only move a live time axis.

#### Scenario: Pointer inside a disconnect
- **WHEN** the pointer is anywhere over the plot inside the 08:30:20 to 08:30:28 region of a disconnect
- **THEN** the readout shows "Not recorded", "Node disconnected", 08:30:20 to 08:30:28, and 8 s, and no reading

#### Scenario: Pointer inside an ongoing gap
- **WHEN** the pointer is inside the region of a gap that started 3 minutes ago and is still open
- **THEN** the readout shows the reason, the start, "ongoing" and about 3 min

#### Scenario: Pointer next to a region
- **WHEN** the pointer moves from inside a region to a reading outside it
- **THEN** the plot's usual tooltip with the readings is shown again, unchanged

### Requirement: Gap reasons
The reason of a gap SHALL come from how the recording span before it ended. Gaps a plot receives with a load, a reply or a live event SHALL all carry it. It SHALL be shown as:

| Recording span ended because | Shown as |
| --- | --- |
| the node disconnected | Node disconnected |
| the node was deactivated | Node deactivated |
| its services stopped | Recording stopped |
| the host suspended, or the server stopped without closing it | Recording interrupted |
| unknown | no reason line |

#### Scenario: Suspend inside a session
- **WHEN** a session has a span ending at 08:59:50 because the host suspended, and the next from 09:12 on
- **THEN** hovering its gap from 08:59:50 to 09:12 shows "Recording interrupted"

#### Scenario: Live disconnect
- **WHEN** a live plot is open and its node disconnects
- **THEN** hovering the new region shows "Node disconnected"
