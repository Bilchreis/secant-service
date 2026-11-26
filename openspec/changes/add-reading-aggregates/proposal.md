# Proposal

## Why

Historical plots thin long recordings at query time, and for arrays and structs that is slow. On the bench's 72 h recording, an array or a struct takes about 1.7 s per initial load. Almost all of that is the thinning query, which reads and unnests every reading in the window (see #172 and #173). The query does the same work on every load and gets slower as a recording grows, and recordings can run for weeks. TimescaleDB continuous aggregates move that work into a background refresh. On the bench, a 15-minute per-element envelope of the 50-element array came back in about 160 ms from 1-minute aggregate rows, against 1.7 s today. This change sets up the aggregates and a way to read them. A later change will switch the plots over to them.

## What Changes

- New continuous aggregates over `readings`, at a 1-minute tier and a 1-hour tier built on top of it, kept up to date by background refresh policies:
  - **Numbers** (`double`, `int`, `scaled`): min, max and mean per bucket (mean is stored as sum and count, so it can be rolled up). Also stored: when the min and max occurred, and the bucket's first and last value with their timestamps.
  - **States** (`enum`, `bool`): one row per state that occurs in a bucket, with its first and last timestamp and its count. This matches today's `:each_state` picker. Bool is not plotted today and gets aggregates now so that bool plots can use them later.
  - **Arrays** of these types: the same aggregates per element, for arrays of any length.
  - **Struct and tuple members, depth 1**: the same aggregates for each direct member that is a number, state, or array of those, keyed by member name (struct) or position (tuple).
- Some readings get no aggregates:
  - strings and arrays of strings;
  - arrays of structs or tuples;
  - members nested deeper than depth 1 (`Channels` plots these today, and they will keep using today's thinning);
  - values kept in `value_json` because they did not fit the declared type.
- A read function that returns a parameter's aggregate buckets for a time window and a bucket width. It rolls up from the coarsest tier the width allows, and reports how far the aggregates have been materialized.
- One migration creates the views and policies. Existing recordings are backfilled by the refresh policies in the background, not inside the migration.

**Out of scope:**
- Switching `History`, `Channels` or any plot to the aggregates, and stitching the not-yet-materialized tail onto them from raw readings. That is the follow-up change.
- Plotting bools, tuples, or anything not plotted today.
- Choosing between drawing the min/max envelope and fetching the readings at the extremes. The aggregates store each extreme's value and time, and the reading id is part of the stored key. The read API returns the value and time but not the id. Looking up the exact reading is left to the follow-up change.
- Aggregates for channels that will keep using raw thinning: members nested deeper than depth 1, and channels drawn with a non-default picker.
- Changing how readings are stored, the `readings` hypertable, or its compression.
- Tiers finer than 1 minute. Windows short enough to need them keep using today's thinning, which is fast for short windows.

## Capabilities

### New Capabilities
- `reading-aggregates`: per-bucket summaries of plottable parameter readings, kept up to date in the background at fixed tiers, and readable for a window at a chosen bucket width.

### Modified Capabilities

None. No existing specs; plot behaviour does not change in this change.

## Impact

- **Database:** eight new continuous aggregates (numbers, states, member numbers and member states, each at 1 min and 1 h), their refresh policies, the columnstore on the four 1-minute views, and the 12 background jobs those run. They add storage. Per-element arrays are the largest part: about 75 MB for 72 h of the bench's parameters, including a 50-element array at 1 s, and 18 MB after compression.
- **Code:** custom statements on `SecantService.SecNodes.Reading` (so `ash.codegen` generates the migration), a new read module under `SecantService.PlotDB`, and tests. `History`, `Channels` and the plots are unchanged.
- **Tests:** a continuous aggregate can't be refreshed inside the sandbox transaction, so the aggregate tests run outside it and clean up after themselves.
- **Bench:** `bench/history_plots.exs` gets an aggregate read case, so the follow-up change has a baseline.
