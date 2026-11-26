# Design

## Context

- All readings live in one hypertable, `readings`, with one-day chunks that are compressed after a day and segmented by `parameter_id`. `Reading.Storage.column/1` picks the column from the datainfo:
  - `double` goes to `value_float`; `int`, `scaled` and `enum` all go to `value_int`; `bool` goes to `value_bool`.
  - Numeric, enum and bool arrays go to typed array columns. `scaled` and `enum` arrays use `value_int_array`.
  - Structs and tuples go to `value_json` as `{"value": …}`.
  - A value that does not fit its declared type also goes to `value_json`, as `{"type": …, "value": …}`.
- The column therefore does not say whether a value is an int or an enum, and struct members are untyped JSON numbers. Only the parameter's `datainfo` says which aggregate a value belongs in.
- `History` (`lib/secant_service/plot_db/history.ex`) thins at query time. `Channels` decides per type what to keep: `:extremes` for numbers and `:each_state` for enums. Bool and tuples are not plotted. These aggregates are designed so that `History` can later read them instead of thinning the raw readings.
- TimescaleDB is 2.32.1 (the `timescale/timescaledb:2.32.1-pg18` image). Every SQL feature this design relies on was checked on the bench database, and the test objects were dropped afterwards:
  - a continuous aggregate joined with `parameters` and filtered by datainfo type;
  - `unnest … WITH ORDINALITY` and `jsonb_each` / `jsonb_array_elements` laterals;
  - an immutable SQL set-returning function in `FROM`;
  - a 1-hour aggregate built on a 1-minute one.

## Goals / Non-Goals

**Goals:**
- Summaries that roll up exactly from 1 minute to any multiple of it. That rules out storing a mean on its own; it is stored as sum and count.
- Ties go to the earliest reading, and to the lower `id` on equal timestamps, so a window always comes back the same, as `History` does today.
- No heavy work in the migration. Existing recordings are backfilled by background jobs.
- A read path whose cost depends on the number of buckets in the window, not on the number of readings.

**Non-Goals:**
- Real-time aggregation (`materialized_only = false`). The follow-up change reads the tail after the watermark from raw readings, which `History` can already thin.
- Re-materializing old buckets when a parameter's datainfo changes (see Risks).
- Aggregates for what `History` will keep thinning from raw readings: members nested deeper than depth 1, which `Channels` plots today, and channels drawn with a non-default picker.
- Arrays whose positions have no stable meaning, such as event lists from neutron instruments, sorted peak lists or sample buffers. Ragged arrays are aggregated by position, which suits spectra and channels but makes no sense for these. A later change could let the node declare how to read such an array, through a custom parameter property, and skip or aggregate those parameters differently.

## Decisions

### 1. Continuous aggregates, not query-time thinning or an app-maintained rollup table

TimescaleDB refreshes continuous aggregates incrementally. It tracks inserts, late inserts and deletes through its invalidation log, so `NodeDBWriter` and the node processes are untouched. An app-maintained rollup table would need writes on the ingest path and its own handling of late data and deletes. Query-time thinning is what makes arrays and structs cost 1.7 s on the bench today.

### 2. Four views per tier, split by where the value comes from and what is stored

| View (`_1m`, `_1h`) | Rows from | Group key | Stored |
|---|---|---|---|
| `reading_numbers` | `value_float`, `value_int`, `value_float_array`, `value_int_array` of `double`/`int`/`scaled` params and arrays of them; the length (idx 0) of every aggregated array, including `value_int_array` of enum arrays and `value_bool_array` | `parameter_id, bucket, idx` | `lo`, `hi`, `sum`, `count`, `first_key`, `last_key` |
| `reading_states` | `value_int`, `value_bool`, `value_int_array`, `value_bool_array` of `enum`/`bool` params and arrays of them | `parameter_id, bucket, idx, state` | `first_at`, `last_at`, `count` |
| `reading_member_numbers` | `value_json->'value'` of `struct`/`tuple` params, number members | `parameter_id, bucket, member, idx` | as `reading_numbers` |
| `reading_member_states` | the same, enum and bool members | `parameter_id, bucket, member, idx, state` | as `reading_states` |

- **A scalar is a one-element array (`idx = 1`)**, so scalars and arrays share a view. The column views unnest a `coalesce` of the array columns and a one-element `ARRAY[...]` of the scalar column, cast to float8 for numbers and to bigint for states. The typed array is unnested first, and each bool then becomes 0 or 1 through `CASE WHEN b THEN 1 WHEN NOT b THEN 0 END`, because `bool::bigint` is not a valid cast. A NULL stays NULL.
- **The length comes from the typed array columns only** (`coalesce(cardinality(value_float_array), cardinality(value_int_array), cardinality(value_bool_array))`; the array columns have different types, so they can't be coalesced themselves), never from the scalar fallback. A reading of an array parameter that did not fit its type is in `value_json`, so its typed array columns are NULL and it gets no length row. An empty array gets a length row of 0 and no element rows.
- **The array length is element `idx = 0` of `reading_numbers`**, for every aggregated array, including enum and bool arrays. SECoP arrays may be ragged (`minlen < maxlen`): per-position rows alone can't say where an array ended in a bucket. A ragged array's element can keep a `last` from an earlier, longer reading. The length's `last` shows that, and its `count` is the bucket's reading count. Built by prepending `cardinality(arr)` to the unnested elements for number arrays, or unnesting `ARRAY[cardinality(arr)]` alone for enum and bool arrays. Fixed-length arrays store a constant, which compresses to almost nothing.
- **Which rows each column view admits:**
  - `reading_numbers`: `type IN ('double','int','scaled')` (scalar, idx 1), or `type = 'array'` with `members->>'type' IN ('double','int','scaled')` (idx 0 and elements), or `type = 'array'` with `members->>'type' IN ('enum','bool')` (idx 0 only).
  - `reading_states`: `type IN ('enum','bool')` (scalar, idx 1), or `type = 'array'` with `members->>'type' IN ('enum','bool')` (elements only, no idx 0).
  - So an enum or bool array's length is a number, and its elements are states.
- **Four views, not one:** TimescaleDB does not allow `UNION` in a continuous aggregate. States need the state in the group key, numbers must not have it. Typed columns and JSON unpack differently, and keeping them apart keeps the typed-column view fast (no JSON decode).
- **Alternatives considered:**
  - Separate scalar and array views: 8 views per tier for no measured gain.
  - Separate struct and tuple views: avoided with the member function in decision 4.

### 3. The type comes from a join with `parameters`

Every view joins `parameters` and filters on `datainfo->>'type'`, or on `datainfo->'members'->>'type'` for arrays. That is the only way to keep enums out of the number views and ints out of the state views. Without the join, grouping every `value_int` by value would create one state row per distinct counter value. TimescaleDB accepts such a join, and it was tested.

### 4. Struct and tuple members are unpacked by one immutable SQL function

A function `reading_member_values(reading jsonb, datainfo jsonb) RETURNS TABLE(member text, idx int, type text, v jsonb)` is created by the same migration. `type` is the member's declared element type (`double`, `int`, `scaled`, `enum` or `bool`), or `length` for an array member's idx 0 row. The views need the declared type to validate the value (decision 6). The argument is not called `value`: inside the function that name would be shadowed by the `value` column of `jsonb_each` and `jsonb_array_elements`, and every member would silently come back NULL. The function:
- yields struct members keyed by name and tuple members keyed by 0-based position as text;
- unpacks array members into elements (1-based `idx`), with `idx = 1` for a scalar member;
- yields, for each array member of any aggregated element type, its length as `idx = 0` with `type = 'length'`, as decision 2 does for top-level arrays;
- yields only members whose declared type (or array element type) is `double`, `int`, `scaled`, `enum` or `bool`. Nested structs, tuples and strings yield nothing, which is how depth 1 is enforced;
- checks shapes before unpacking: a struct reading must be a JSON object and a tuple reading a JSON array (`jsonb_typeof`), and an array member must be a JSON array. A reading or member of the wrong shape yields nothing instead of failing the refresh;
- unpacks an array member only if every element fits its declared type, as `Reading.Storage` decides for a top-level value: a double within float8 (up to its largest finite number as an exact integer, as in `Storage`), an int, scaled or enum a whole number within bigint, a bool a boolean. The check runs once per member (a lateral subquery with `OFFSET 0`, so Postgres doesn't pull it up into both branches). A top-level array with such an element is kept as JSON and not aggregated, so an array member like that yields neither its length nor its elements. The struct's other members are still aggregated.

Both member views call it. `reading_member_numbers` takes `type IN ('double','int','scaled','length')` and `reading_member_states` takes `type IN ('enum','bool')`, and both validate `v` as decision 6 describes.
- **Measured:** a full refresh of the 72 h struct took 5.2 s with the function and 3.6 s with the SQL written into the view, with the function as first written, which Postgres did not inline. A non-`STRICT` SQL function made of a single `SELECT` was inlined into the plan in round-3 testing, so the function is written that way and not marked `STRICT`. Implementation confirmed it: `EXPLAIN` of the member view's query shows no scan of `reading_member_values`, only the `jsonb_each` and `jsonb_array_elements` inside it, so the view runs the same plan as SQL written into it. Accepted either way: a refresh only processes new buckets, so this costs time only once, during backfill.
- **Alternative:** writing the SQL into each view duplicates the struct and tuple branches four times (two views per tier, two tiers).

### 5. Extremes, first and last are stored as float8 array keys

With `t` = the reading's time in epoch microseconds (`round(date_part('epoch', timestamp) * 1e6)`, float8) and `id` = the reading's `id`:
- `lo = min(ARRAY[v, t, id])`, `hi = max(ARRAY[v, -t, -id])`.
- `first_key = min(ARRAY[t, id, v])`, `last_key = max(ARRAY[t, id, v])`.
- `sum = sum(v)` (float8), `count = count(*)`.

Why:
- One column holds a value together with when it occurred, and `min()`/`max()` roll the keys up exactly. This is the key pattern `History` already uses.
- Ties go to the earliest reading, and readings with the same timestamp are ordered by `id`, as `History` sorts them. The result does not depend on scan order or compression.
- `t` is an integer number of microseconds, exact in float8. `round(date_part(…) * 1e6)` was exact on 2 M microsecond timestamps on the bench, in every year tested from 1971 to 2105, and loses exactness from 2106-02-07 (epoch 2^32 s). Timestamps after that are not supported by these keys. It is float8 arithmetic. `extract(epoch …)` returns numeric and made the refresh about twice as slow, as `History` already notes for its own query. `id` is exact up to 2^53.
- `sum` stays float8, because a numeric sum made the aggregation about 64% slower. A float8 `sum()` raises an error on overflow, and that error would fail every later refresh. Decision 6 rules overflow out: it keeps only values with `abs(v) < 1e290`, so a bucket would need more than 10^18 readings to overflow. The mean (`sum / count`) is a float8 sum, and rolling up float sums is not bit-exact, so tests compare means with a tolerance.
- Values are float8. Integers above 2^53 lose precision and are compared as float8. Two such values can then compare equal, and an extreme's time can come from the wrong one of them. A plot can't show the difference.
- The reader turns the keys into plain fields (`min`, `min_at`, `max`, `max_at`, `first`, `first_at`, `last`, `last_at`).

**Rollup to `_1h` and in the read API:**
- Number views: `min(lo)`, `max(hi)`, `sum(sum)`, `sum(count)::bigint`, `min(first_key)`, `max(last_key)`. The cast keeps `count` a bigint in both tiers, since `sum(bigint)` returns numeric.
- State views: `min(first_at)`, `max(last_at)`, `sum(count)::bigint`, grouped with the state.
- The read API uses the same expressions, including the casts, so counts come back as integers.

**Alternatives:**
- Separate `min` and `first(ts, v)` columns. Ties would go to whichever row the scan reaches first, which changes with compression.
- TimescaleDB's `first(v, ts)`/`last(v, ts)`. They have no tie-break on equal timestamps.
- **No median, not even for `int`.**
  - A `percentile_disc(0.5)` column works in a `_1m` view: tested, 1.7 s for the 72 h refresh.
  - But a median doesn't roll up. Coarser buckets and the `_1h` tier would hold medians of medians.
  - An exact median would need a count per distinct value. That gives about one row per reading for counters and raw ADC values.
  - An approximate median that rolls up correctly (`percentile_agg`) needs the TimescaleDB Toolkit, which the `timescale/timescaledb` image doesn't ship.
  - Min and max already cover the spikes the envelope is drawn for.

### 6. Values that are left out

- **Number views** keep a value only if `abs(v) < 1e290`. That drops NaN, ±Infinity and values too large to sum safely (decision 5). No instrument reading comes near 1e290.
- **Member numbers** must be JSON numbers within that range, checked on `numeric` before any cast to float8, as `History.values/3` does. Members declared `int` or `scaled` must also be within bigint, as a top-level `int` must. JSON accepts numbers such as `1e400` and `1e-400`, and casting them to float8 raises an error. So the check is `abs(n) < 1e290 AND (n = 0 OR abs(n) > 2.4703282292062328e-324)` on `n = v::numeric`, and only then `n::float8`. The lower bound is half the smallest subnormal double: a nonzero number at or below it rounds to zero, and the cast raises. Members declared `int` or `scaled` (and enums) must also be whole numbers (`n = trunc(n)`) within bigint. Unlike a top-level `int`, whose floats `Reading.Storage` keeps as JSON, a whole-number float in a member counts as an integer: once in `jsonb` it can't be told from one. Jason writes `1000.0` as `1.0e3`, which `jsonb` stores as the integer 1000, and checking the scale would treat `2.0` and `1000.0` differently. Fractional values, such as 1.5, are left out. JSON has no NaN or Infinity, so members can't hold them.
- **State views keep only non-NULL states.** An enum or bool reading that did not fit its type has NULL in its typed column, and the scalar `ARRAY[value_int]` would otherwise unnest it into a NULL state.
- **Member enum states** must be JSON numbers with no fractional part, within the bigint range (−2^63 ≤ v < 2^63). A 1.5 would otherwise be cast to state 2, and a 1e30 would fail the refresh with `bigint out of range`. Oldest-first batches would then retry the failing batch on every run, and the view would stop advancing for every parameter.
- **Member bool states** must be JSON booleans, mapped to 0 and 1 with `CASE`.
- **Every JSON check is a nested `CASE` that only casts after its checks pass**, as in `History.values/3`, never `WHERE` conjuncts, whose evaluation order Postgres does not guarantee. A value that fails a check becomes NULL and is filtered out.
- **Member values of the wrong shape** (decision 4) yield nothing.
- **Values that did not fit their type** (`value_json` with a `"type"` key) are skipped. The column views never read `value_json`. The member views only read params of type `struct` or `tuple`, and also require `NOT value_json ? 'type'`, which drops a struct stored as `{"type", "json"}` because it holds a NUL character. That is also how `History` skips them today.

### 7. Tiers and refresh policies

- **`_1m`:**
  - `schedule_interval => 1 minute`, `start_offset => NULL`, `end_offset => 1 minute`.
  - `buckets_per_batch` bounds each batch and its transaction. `max_batches_per_execution` stays at its default (`NULL`, no limit), so one run works off everything that is pending. A capped run does not reschedule early, so after a purge only one capped run per minute would work off the invalidated range, and the newest data would wait behind it. A run's length is therefore unbounded. Each batch commits on its own, the job's `max_runtime` is 0, and the next run is scheduled after the previous one finishes. Task 3.2 picks `buckets_per_batch`, and records the duration and batch count of one run on a sparse and a dense fixture.
  - Batches run oldest first: `refresh_newest_first => false`, passed explicitly on all eight policies, because the TimescaleDB 2.32.1 default is newest first. Newest first would make recent data available sooner, but the watermark would jump to the newest bucket while older ranges are still empty.
- **`_1h`:** built on `_1m` (a hierarchical aggregate), `schedule_interval => 15 minutes`, `end_offset => 1 hour`, the same batching. Materializing `_1m` invalidates the `_1h` buckets above it, so the next `_1h` run corrects an hour that was materialized while `_1m` was still incomplete. Until then, that hour is stale (decision 9).
- **Why `start_offset => NULL`:** a refresh only re-materializes invalidated buckets, so a policy over the whole range costs no more than over a fixed recent range. It also picks up late readings and deletes anywhere, including a deleted parameter's readings, which a fixed `start_offset` would leave stale.
- **Why 1 min + 1 h:** with 400 buckets per chart, the 1-minute tier serves windows from about 7 h up, and the 1-hour tier keeps a multi-week window to a few hundred rows per element. Shorter windows keep using today's thinning, which is fast for them.

### 8. Columnstore on the aggregates

Each view is created with `timescaledb.create_group_indexes = false` and one explicit index, `(parameter_id, bucket)`. TimescaleDB still keeps its `(bucket DESC)` index, so each view has two indexes. The default group indexes include an `(idx, bucket)` index that no query uses, and the indexes were 16 of the 75 MB on the bench. The four `_1m` views get the columnstore, segmented by `parameter_id`, ordered by `bucket`, with a policy after 2 days. The `_1m` number view of a wide array is the largest object (see Risks). Refreshing into a compressed region is supported in this TimescaleDB version. The `_1h` views are 60 times smaller and get no columnstore: four fewer jobs, and their reads stay uncompressed.

### 9. Read API: `SecantService.PlotDB.Aggregates`

- `numbers(param, from, to, bucket_ms)` and `states(param, from, to, bucket_ms)` return `{:ok, %{tier:, materialized_until:, buckets: [...]}}`, `{:error, :unsupported_width}`, or `{:error, :not_aggregated}`. The last one comes back when the parameter has no aggregates of that kind: `numbers/4` on a string or a scalar enum, `states/4` on a double, or either on a struct or tuple with no direct member of that kind, judged from the declared members.
- The function picks the column or member view from the datainfo, and the coarsest tier that divides `bucket_ms` (`_1h` when it divides, else `_1m`; below 1 minute or not a multiple of it, an error).
- **Window edges:** `from` and `to` are floored to the width in SQL, with `time_bucket(width, …)`, so the window uses the same origin as the rollup, also for multi-day widths. This is the normalized window: half-open, `[floor(from), floor(to))`. A bucket is returned only if it lies fully inside the normalized window and ends at or before `materialized_until`.
- It rolls up with `time_bucket(width, bucket)` in one Ecto query, using the rollup in decision 5. Each bucket is a map with `bucket`, `member` (nil for non-member views), `idx`, and the plain fields. The query returns `sum` and `count`, and the mean (`sum / count`) is computed in Elixir. In SQL, `5e-324::float8 / 3` raises an underflow error, while Elixir returns 0.0.
- **`materialized_until`** comes from the watermark (`_timescaledb_functions.cagg_watermark`) and is selected in the same query.
  - For `_1h` it is the smaller of the `_1h` and `_1m` watermarks.
  - It is a high-water mark only: no bucket after it has been materialized. It does not promise that the buckets before it exist or are current. A manual refresh over a limited range moves it past buckets that were never materialized, and `refresh_continuous_aggregate` itself runs newest first.
  - A late reading, a delete, or an hour materialized while `_1m` was incomplete appears after the next successful refresh that covers it. Policy runs are oldest first (decision 7), but the design promises no wall-clock bound.
  - It never moves back, not even when every reading is deleted.
  - A view that has never been refreshed reports the lowest timestamp (4714-11-24 BC). That is returned as `nil`, with no buckets.
  - Whether a plot may use it as the cutoff for raw readings, and when a plot switches over during backfill, is decided in the follow-up change.
- The plain Ecto query follows how `History` reads `readings`. These views are read-only, so Ash resources for them would add nothing.
- **Query count and payload on a long recording** (72 h at 1 reading/s, 15-minute buckets, so at most 288 complete buckets):
  - One query per call. A struct with number and state members needs two calls.
  - About 288 rows for a scalar, 288 × 51 = 14,688 rows for a 50-element array (50 elements plus the length at idx 0), and 288 × (number of states) for an enum.
  - For 4 weeks at 2-hour buckets from `_1h`: 336 rows per element, read from 672 stored rows.
  - Measured with `Aggregates.numbers/4` on the bench (task 6.1), 15-minute buckets over 72 h, median of 5 runs, with the 1-minute views uncompressed and compressed:

    | Parameter | Buckets returned | Uncompressed | Compressed |
    |---|---|---|---|
    | double | 288 | 10 ms | 12 ms |
    | struct (4 number members) | 1,152 | 24 ms | 26 ms |
    | 50-element array | 14,688 | 380 ms | 336 ms |
    | 1000-element array | 288,288 | 5.7 s | 8.5 s |

    Today's thinning takes 1.7 s for the 50-element array. The times include decoding the rows into maps in Elixir.

### 10. Migration via custom statements on `Reading`

- The function, the 8 views, their refresh policies and the columnstore on the `_1m` views go in `custom_statements` on `SecantService.SecNodes.Reading`, after the hypertable statements, so `mix ash.codegen` generates the migration and tracks it in the snapshots, as for the hypertable. The `_1h` statements come after their `_1m` source.
- **`up`:** creates each view `WITH NO DATA`, so the migration takes as long as creating 8 empty views (seconds), however much data exists.
- **`down`:** drops the views in reverse order (policies go with them): the four `_1h` views, then the four `_1m` views, then the function.
- **Effect on existing hypertable data:** none. `readings`, its chunks and its compression are not changed. Existing recordings are backfilled by the policies after the migration, oldest first.
- **During implementation** each step is generated with `MIX_ENV=test mix ash.codegen --dev` and migrated on the test database only.
  - Task 4.1 folds the dev migrations into the named migration, also under `MIX_ENV=test`. Folding rolls back only the dev migrations recorded in the current environment's `schema_migrations`, then deletes the dev files. The dev migrations were applied to the test database, so they must be rolled back there. In dev, the fold would roll back nothing and still delete the files.
  - No other database gets the dev migrations. `bench/history_plots.exs` applies every pending migration, so it is not run until the fold is done. Bench timings before that use hand-made copies of the view SQL (task 3.2).

## Risks / Trade-offs

- **[Per-element rows for wide arrays are large]** A 1000-element spectrum gives 1001 `_1m` rows per minute, about 1.44 M a day, however often it reads.
  - Measured in task 6.1: on the bench, `reading_numbers_1m` over 72 h held 4.56 M rows, 4.32 M of them from a 1000-element array. It took 1184 MB uncompressed and 257 MB compressed. That is about 395 MB a day uncompressed and 85 MB a day compressed for one such array. `reading_numbers_1h` took 20 MB.
  - → Accepted. The columnstore policy compresses the 1-minute views after 2 days.
- **[A wide array at a fine width is a large read]** 15-minute buckets of the 1000-element array over 72 h are 288,288 rows and took 5.7 s (8.5 s compressed). → For the follow-up: a plot of a wide array needs coarser buckets or fewer elements than a scalar's.
- **[The join reads the current `parameters` row]** A continuous aggregate does not re-materialize when a joined table changes. In practice this can't happen: `secant_client` issues a new uuid whenever a node's description changes, so a changed datainfo comes with a new SEC node and new parameter ids (see `NodeManager`). The `Parameter` upsert only rewrites an identical description.
- **[Backfill load after deploy]** The first policy runs materialize every existing recording. → Batched (`buckets_per_batch`), oldest first, in TimescaleDB background workers, so node connections and ingest are not involved. Recent data becomes readable only once the backfill reaches it. That is acceptable, because nothing reads the aggregates in this change.
- **[The nightly purge re-aggregates broadly]** `purge_trashed_nodes` (03:00) deletes a trashed SEC node's readings by cascade. TimescaleDB invalidates the whole time range of the deleted rows, for every parameter, so the next refresh re-materializes that range for all parameters, not just the deleted ones. The cost depends on the purged time span and on how many readings other parameters have in it, not on how many parameters were deleted. The purge also runs on demand from the data browser.
  - Measured in task 3.3 with the final views, on a copy of the bench readings (72 h, 1.07 M readings), with the 1-minute policies at 360 buckets per batch:

    | Deleted | Invalidated span | `reading_numbers_1m` run | `reading_member_numbers_1m` run |
    |---|---|---|---|
    | none (first backfill) | 72 h | 14.7–15.2 s | 7.4–7.7 s |
    | a node with 2 h of readings | 2 h | 0.5 s | 0.3 s |
    | one parameter of a 72 h recording | 72 h | 14.8 s | 7.3 s |

    So a purge costs about as much as the first backfill of the span it deletes from. In both cases the deleted buckets were gone after that one run, and a reading inserted after the delete appeared at the end of the same run.
  - Until the invalidated range is worked off, oldest first, the newest buckets wait: in the 72 h case, about 15 s for the number view.
  - → Accepted by the user, with `start_offset => NULL` kept, so deletes and late readings are always reflected. The task 3.3 measurements above were reported to the user. A finite `start_offset` would cap the cost but leave older deletes and late readings stale.
- **[The watermark uses an internal function]** `_timescaledb_functions.cagg_watermark` is not public API. → It is isolated in the read module and covered by a test that inserts readings newer than any other test's, refreshes, and checks that `materialized_until` lands at the end of their newest bucket. An upgrade that changes the function then fails the test suite. There is no silent fallback: `max(bucket)` is not a completeness boundary.
- **[`CREATE OR REPLACE` doesn't re-materialize]** Changing `reading_member_values` in place changes how new buckets are built, but already materialized buckets stay as they were. → The `Reading` moduledoc says that a change to the function, like a change to a view, needs a migration that drops and recreates the views. The new views are then backfilled by their policies. A manual `refresh_continuous_aggregate` runs newest first, unless its batching `options` say otherwise.
- **[Compressed aggregate reads are not much slower]** In task 6.1, the 50-element array read in 336 ms from compressed `_1m` rows against 380 ms uncompressed. The 1000-element array took 8.5 s against 5.7 s (decision 9). → Accepted.
- **[Manual refreshes are slow unless batched]** `refresh_continuous_aggregate` without `options` runs in 10-bucket batches, newest first. Over the bench's 72 h, `reading_states_1m` took 30 s that way, and 1.0 s with `options => '{"buckets_per_batch": 360, "refresh_newest_first": false}'`, the policies' batching. With that batching, `reading_numbers_1m`, including the 1000-element array, took 40 s. → The bench and the `Reading` moduledoc use the policies' batching. The test helper refreshes small fixtures, where it doesn't matter.
- **[Sandbox tests can't refresh]** `refresh_continuous_aggregate` cannot run inside a transaction. → The aggregate tests run setup, assertions and cleanup with `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`, `async: false`, without `DataCase`'s shared sandbox owner. They delete their own SEC node in an `on_exit`, then refresh again to clear the views.
- **[Policy jobs also run on the test database]** The 12 jobs run there too, and the watermark of the shared test views never moves back. → The aggregate tests pause the refresh jobs (`alter_job(…, scheduled => false)`) and resume them in `on_exit`. They assert relative to the `materialized_until` a call returns, test the never-refreshed sentinel on a view created for that test, and seed typed NaN readings with SQL, because the storage helper does not accept a NaN float.
- **[Refresh cost of the member function]** It refreshes about 1.45× slower than SQL written into the view. → Only backfill notices this. If it matters, the function can be replaced by SQL written into the views without changing their output.
- **[12 more background jobs]** 8 refresh jobs and 4 columnstore jobs. Each `_1m` refresh job runs every minute, but in steady state a run only processes the buckets invalidated since the last run, so it is cheap. The server allows 16 TimescaleDB background workers (`timescaledb.max_background_workers`), and the dev, test and bench databases share them. → During backfill, jobs can queue behind each other, which only delays them. If jobs miss their schedule, raise the worker limit in the database container.
