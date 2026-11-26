# Tasks

Every `ash.codegen` command in this change runs under `MIX_ENV=test`, including `--dev` and `--check`. Dev migrations are applied to the test database only. Never apply them to the dev database, and do not run `bench/history_plots.exs` before task 4.1, because it applies every pending migration to the bench database.

## 1. Member function and column-backed number view

- [ ] 1.1 Load the `ash-framework` skill. Add custom statements to `SecantService.SecNodes.Reading`, after the hypertable statements:
  - the `reading_member_values(reading jsonb, datainfo jsonb)` function (design decision 4, with the shape guards and the declared `type` column);
  - `reading_numbers_1m` `WITH NO DATA`, following design decisions 2, 3, 5, 6 and 8:
    - the `round(date_part(…) * 1e6)` time key;
    - the float8 sum;
    - the `abs(v) < 1e290` guard;
    - the length taken from the typed array columns only;
    - `create_group_indexes = false` with one `(parameter_id, bucket)` index;
  - `down` statements that drop them.

  Generate a dev migration with `MIX_ENV=test mix ash.codegen --dev` and apply it with `MIX_ENV=test mix ecto.migrate`. Verify that the statements come out in order and the test database migrates.
- [ ] 1.2 Add a test helper in `test/support/`. It runs setup, assertions and cleanup outside the sandbox with `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`, without `DataCase`'s shared owner. It:
  - pauses the aggregate refresh jobs (`alter_job(…, scheduled => false)`) and resumes them in `on_exit`, looking them up by view and tolerating none (they exist only from task 3.1 on);
  - creates a SEC node, module and parameter with a given datainfo;
  - inserts readings through `Storage.to_row/4` and `SecNodes.insert_readings/1`, and typed NaN readings through SQL;
  - calls `refresh_continuous_aggregate` for a named view;
  - in `on_exit`, deletes the SEC node and refreshes again.

  Verify it with the first test of 1.3, and check that no SEC node is left behind.
- [ ] 1.3 Write tests in `test/secant_service/reading_aggregates_test.exs` for `reading_numbers_1m`. Cover these spec scenarios:
  - double bucket;
  - equal extremes;
  - readings with the same timestamp;
  - very large values;
  - integers beyond float precision;
  - scaled stays unscaled;
  - per-element extremes;
  - readings of different length;
  - ragged array shrinks;
  - enum array length;
  - fixed-length array;
  - empty array;
  - array reading that did not fit its type;
  - NaN reading;
  - value that did not fit its type;
  - enum not in numbers.

  Compare means with a tolerance and everything else exactly. Verify the tests pass.

## 2. State views and member views

- [ ] 2.1 Add `reading_states_1m`, `reading_member_numbers_1m` and `reading_member_states_1m` as custom statements, with the nested-`CASE` guards of design decision 6. Generate them with another `MIX_ENV=test mix ash.codegen --dev` and migrate the test database. Test them against these spec scenarios:
  - enum changes state;
  - bool as 0/1;
  - int is not a state;
  - a struct with number, enum, array and nested-struct members;
  - a tuple member;
  - a member with an unexpected value;
  - a member nested two levels deep;
  - a member number too large (a 400-digit integer and 1e-400);
  - a fractional enum value;
  - an enum value out of range;
  - a reading of the wrong shape;
  - the length (element 0) of an array member.

  Also test that a fractional value of an `int` member is left out, and the spec scenario "Enum reading that did not fit its type" (no NULL state row). Add these to `reading_aggregates_test.exs` and verify they pass.
- [ ] 2.2 Test `reading_member_values` directly. Cover at least:
  - struct, tuple and array members with their `length` row (idx 0), including enum and bool arrays;
  - the declared `type` of each row;
  - nested struct skipped;
  - string member skipped;
  - a struct reading that is a JSON array;
  - a tuple reading that is an object;
  - an array member that is not an array;
  - a value that is neither object nor array.

  Compare the refresh time of the function, written as a non-`STRICT` single-`SELECT` SQL function, with the same SQL written into the view on a small fixture, and note it in design decision 4. Verify the tests pass.

## 3. Hourly tier, policies and columnstore

- [ ] 3.1 Add these as custom statements, through `MIX_ENV=test mix ash.codegen --dev` on the test database:
  - the four `_1h` views on top of their `_1m` sources (rollup of design decision 5, with `sum(count)::bigint`);
  - the refresh policies of design decision 7: `start_offset => NULL`, an explicit `refresh_newest_first => false`, and `max_batches_per_execution` left unlimited;
  - the columnstore settings and policies on the four `_1m` views (design decision 8).

  Verify with tests:
  - 1-hour buckets equal the same hour rolled up from `_1m`;
  - `timescaledb_information.jobs` lists one refresh job per view and one columnstore job per `_1m` view, 12 in all, and every refresh job has `config->>'refresh_newest_first' = 'false'`;
  - staggered refreshes: refresh `_1m` for half an hour, then `_1h`, then `_1m` for the rest of the hour. The hour is stale until the next `_1h` refresh, and correct after it.
- [ ] 3.2 Pick `buckets_per_batch` on the bench database, using copies of the view SQL created by hand under a `tmp_` prefix and dropped afterwards. Do not use migrations or the bench script. Add each policy and pause it (`alter_job(…, scheduled => false)`) in one transaction, so the scheduler doesn't race the manual run. Then time one policy run (`CALL run_job(<id>)`) on a sparse and on a dense fixture. Record the value, and each run's duration and batch count, in a comment next to the policy statement.
- [ ] 3.3 Write tests for the spec scenarios "Parameter deleted" (all tiers) and "Late reading" (both tiers). Verify they pass. On the same `tmp_` copies on the bench database:
  - on disposable copies of the source data, time the refresh that follows deleting one SEC node's readings, as the purge does, until the purged buckets are correct again;
  - separately, time how long a newly eligible bucket takes to appear after that delete;
  - record both in the design's purge risk and report them to the user;
  - drop the copies.

## 4. Migration

- [ ] 4.1 Check that `priv/repo/migrations` holds no `_dev` migrations other than this change's. Then fold them into one with `MIX_ENV=test mix ash.codegen add_reading_aggregates`, which rolls back the dev migrations on the test database and deletes them. Migrate the test database again and check the generated migration:
  - each view is created `WITH NO DATA`, and `_1h` after `_1m`;
  - `down` drops the `_1h` views, then the `_1m` views, then the function.

  Verify with `MIX_ENV=test mix ash.codegen --check`, and with `MIX_ENV=test mix ecto.rollback --step 1 && MIX_ENV=test mix ecto.migrate`. Do not run it against the dev database: the user applies it there.
- [ ] 4.2 Document the aggregates in the `Reading` moduledoc:
  - which views exist, what they store, and the tiers;
  - that `materialized_until` is a high-water mark only;
  - that the keys support timestamps up to 2106-02-07;
  - that after recreating a view the policies backfill it, and that a manual `refresh_continuous_aggregate` runs newest first unless its `options` say otherwise;
  - that changing a view or `reading_member_values` needs a hand-written migration that drops and recreates the views, since a continuous aggregate's query can't be altered and `CREATE OR REPLACE` on the function doesn't re-materialize old buckets.

  Verify that `mix docs`, or a compile without warnings, passes.

## 5. Read API

- [ ] 5.1 Add `SecantService.PlotDB.Aggregates` with `numbers/4` and `states/4` (design decision 9). It covers:
  - tier choice;
  - `{:error, :unsupported_width}` and `{:error, :not_aggregated}`;
  - the normalized window, floored in SQL with `time_bucket`, with only fully contained buckets returned;
  - the rollup in one query;
  - decoding the keys into plain fields, and computing the mean in Elixir from `sum` and `count`;
  - `materialized_until` from the watermark (for `_1h`, the smaller of the two), with the minimum sentinel read as `nil`.

  Write tests covering these spec scenarios:
  - "15-minute buckets": compare with buckets computed in Elixir from the raw readings;
  - "Width served from the 1-hour tier";
  - "Width below a tier";
  - "Window past the materialized end": assert relative to the returned `materialized_until`;
  - "Unaligned window";
  - "Never refreshed": call the module's watermark query on a view created for the test (`numbers/4` picks its view from the datainfo), plus a unit test of the sentinel decoding;
  - "Kind of aggregate the parameter does not have".

  Add the watermark test from the design's Risks: readings newer than any other test's, a refresh, and `materialized_until` checked against the end of their newest bucket. Verify the tests pass.
- [ ] 5.2 Assert in a test that one `numbers/4` call issues exactly one query (Repo telemetry, as in `history_test.exs`). Verify it passes.

## 6. Bench baseline

- [ ] 6.1 Only after 4.1, add an aggregate read case to `bench/history_plots.exs`:
  - refresh the bench's aggregates once;
  - time `Aggregates.numbers/4` at 15-minute buckets over 72 h for the double, array and struct parameters, both uncompressed and after compressing the `_1m` views;
  - add a 1000-element array parameter, and report the size of each view before and after compression.

  Run it against `secant_service_bench` only. Record the numbers in the design's Risks section and the proposal's Why and Impact.

## 7. Wrap-up

- [ ] 7.1 Run `mix precommit` and fix everything it reports, until it passes.
