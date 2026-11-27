# Spec Delta

## Purpose

Keeps a durable record of when each session's node was actually being recorded, so time without recording can be told apart from a value that simply did not change.

## ADDED Requirements

### Requirement: A span per stretch of recording
The system SHALL store, per session, recording spans: a start time, a last-alive time and, once closed, an end time and an end reason. Span times SHALL be the server's UTC wall-clock (OS) time. A session SHALL have at most one open span at any time. A closed span SHALL never be reopened or changed. Spans SHALL be deleted when their session is deleted.

#### Scenario: Session deleted
- **WHEN** a trashed session is purged
- **THEN** its recording spans are deleted with it

#### Scenario: One open span
- **WHEN** a node is reported initialized and active twice in a row without a disconnect in between
- **THEN** the session still has exactly one open span

### Requirement: Span opens when recording becomes possible
While the session's node services run, recording becomes possible when the client reports the node initialized and active under this session's uuid, by a state report or an activation report. A span SHALL then open at the next value update, which confirms that values flow. At service start, a node already initialized and active SHALL open a span at once. A report under another uuid SHALL NOT open a span for this session.

#### Scenario: Services start on a connected node
- **WHEN** the node services of a session start and the node is initialized and active
- **THEN** an open span of that session starts at once

#### Scenario: Node activated after its services started
- **WHEN** the node services start while the node is initialized but not yet active, and the node is activated a moment later
- **THEN** a span opens with the first value update after the activation

#### Scenario: Node reconnects
- **WHEN** a node that was disconnected reconnects with an unchanged description and is active
- **THEN** a new open span of the same session starts with the first value update after it is initialized

#### Scenario: Activation fails after a reconnect
- **WHEN** a node reconnects with an unchanged description but sends no value update after it is initialized
- **THEN** no span opens

#### Scenario: Description changed on reconnect
- **WHEN** a node disconnects and reconnects with a changed description, so the client reports it under a new uuid
- **THEN** the old session's span was closed as `disconnected` and gets no new span, and the new session's span opens when its own services start

#### Scenario: Description changed without a disconnect
- **WHEN** a recorded node changes its description while connected, and the node services of the session are stopped for it
- **THEN** the session's open span is closed with reason `stopped`

### Requirement: Values just before activation count
A value update received on the current connection, after the span's last close, and less than 2 seconds of wall-clock time before recording became possible SHALL open the span at once, at that update's time. An update from an earlier connection SHALL NOT.

#### Scenario: Values ahead of the activation report
- **WHEN** a paused node is activated and its first values arrive just before the activation is reported
- **THEN** the span opens at the time of those values

#### Scenario: Quick reconnect
- **WHEN** a node sends a value, disconnects and is reported initialized again within 2 seconds, and then sends nothing
- **THEN** no span opens

### Requirement: Span closes with a reason
An open span SHALL be closed when recording stops, with its end time and one of these end reasons: `disconnected` when the connection to the node is lost or its client process ends, `deactivated` when the node is deactivated (paused), `stopped` when the node services stop cleanly (a description change, a node removed, a server shutdown).

#### Scenario: Node disconnects
- **WHEN** the connection to a recorded node is lost
- **THEN** the session's open span is closed at that moment with reason `disconnected`

#### Scenario: Node deactivated
- **WHEN** a recorded node is deactivated
- **THEN** the session's open span is closed with reason `deactivated`, and a new span opens with the first value update after it is activated again

#### Scenario: Clean shutdown
- **WHEN** the server is stopped cleanly, or a session's node services are stopped, while a node is recorded
- **THEN** the session's open span is closed with reason `stopped`

#### Scenario: Tracking crashes
- **WHEN** the span tracking itself crashes
- **THEN** the open span is not closed by the crash, so the restarted tracking can carry it on

### Requirement: Heartbeat keeps an open span alive
While a span is open and the database is reachable, its last-alive time SHALL be updated at least every 15 seconds, and never set later than the moment of the update.

#### Scenario: Long recording
- **WHEN** a node has been recorded without interruption for an hour
- **THEN** the open span's last-alive time is less than 15 seconds old

### Requirement: Spans left open are closed at their last heartbeat
When a session's span tracking restarts while the server keeps running, a span it left open SHALL be closed at its last-alive time with reason `interrupted`. A span whose last-alive time is less than 45 seconds old SHALL instead be kept open and carried on, if recording is still possible. No span SHALL open before the left-open span has been read. A span left open by a server kill or power loss stays open; plots treat it as ended at its last-alive time.

#### Scenario: Tracking killed and restarted later
- **WHEN** the span tracking is killed and starts again 2 minutes later while the node stays connected
- **THEN** the span that was open is closed at its last heartbeat with reason `interrupted`, and a new span opens

#### Scenario: Tracking restarts at once
- **WHEN** the span tracking of a session crashes and restarts within a few seconds while the node stays connected
- **THEN** the span that was open stays open under the same id, and no gap is recorded

### Requirement: Host suspend ends the span
When the wall clock has moved on more than 30 seconds beyond the time the server itself measured as elapsed (a suspended host, or a clock step), the system SHALL close the open span at its last-alive time with reason `interrupted`. If recording is still possible, a new span SHALL open with the next value update. This check SHALL run before any other change to the span is recorded, so a disconnect noticed after a resume cannot extend the span over the suspend. One suspend SHALL be detected once.

#### Scenario: Laptop lid closed
- **WHEN** the host running the server is suspended for 10 minutes while a node is recorded and then resumes
- **THEN** the span that was open ends at its last heartbeat before the suspend with reason `interrupted`, and a new span starts with the first value update after the resume

#### Scenario: Disconnect noticed right after resume
- **WHEN** the host resumes from a 10-minute suspend and the node's disconnect is reported before the next heartbeat
- **THEN** the span ends at its last heartbeat before the suspend with reason `interrupted`, no new span opens, and the next heartbeat detects no further suspend

#### Scenario: Busy server
- **WHEN** a heartbeat runs 45 seconds late because the server is busy, with no suspend
- **THEN** the open span is kept and only its last-alive time is updated

### Requirement: Spans survive a database outage
While span tracking keeps running, span changes that cannot be written because the database is unreachable SHALL be kept, in order, and written once it is reachable again. On a clean stop the pending changes SHALL be written, up to a few seconds. A database outage SHALL NOT close a span, and SHALL NOT delay recording of readings or the span tracking itself.

#### Scenario: Database down for a minute
- **WHEN** the database is unreachable for a minute while a node is recorded and nothing else happens
- **THEN** once it is back and the pending changes are written, the open span has a current last-alive time and no gap was recorded for that minute
