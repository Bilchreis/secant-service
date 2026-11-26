defmodule SecantService.SecNodes.Reading.AggregateViews do
  @moduledoc """
  The SQL of the continuous aggregates over `readings`, as custom statements
  for `SecantService.SecNodes.Reading`, in the order they are created.

  Each statement is one SQL command, because a migration's `execute/1` runs
  one command at a time. See the `Reading` moduledoc for what the views hold.
  """

  # Types whose readings are aggregated as numbers and as states.
  @number_types "('double','int','scaled')"
  @state_types "('enum','bool')"
  @element_types "('double','int','scaled','enum','bool')"

  # Nonzero JSON numbers whose magnitude is at most this round to zero as
  # float8, and the cast raises: half the smallest subnormal double, rounded
  # up in the last digit. The exact bound, 2^-1075, would need over a thousand
  # digits, and the band between them can't occur: stored numbers come from
  # Elixir floats, written as the shortest decimal of a double (5.0e-324 and up).
  @float8_min "2.4703282292062328e-324"
  # the largest finite double as an exact integer, the bound Reading.Storage
  # uses for integers in a float column
  @float8_max "179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368"

  # The reading's time in epoch microseconds, as an exact float8 (until
  # 2106-02-07, when epoch seconds reach 2^32). `date_part` keeps this in
  # float8; `extract` would compute in numeric, at twice the cost.
  @t ~S|round(date_part('epoch', r."timestamp") * 1e6)|

  # Refresh batches, in buckets: 6 hours of readings for the 1-minute views,
  # a day for the 1-hour views. Each batch commits on its own, and a run works
  # through all pending batches. Timed with one policy run (`CALL run_job`) of
  # a copy of reading_numbers_1m on the bench database (72 h, 8 parameters,
  # 1.07 M readings including a 50-element array):
  #
  #   buckets_per_batch   batches   dense 72 h   + 30 days of sparse readings
  #   60                  72        16.5 s       17.5 s
  #   360                 12        12.3 s       12.6 s
  #   1440                3         13.6 s
  #
  # The 1-hour view's run over the same 72 h took 0.35 s with 24 and 0.30 s
  # with 168 buckets per batch.
  @minute_batch 360
  @hour_batch 24

  @doc "The custom statements, as `%{name:, up:, down:}`."
  def statements do
    [
      %{
        name: :reading_member_values,
        up: member_values_function(),
        down: "DROP FUNCTION reading_member_values(jsonb, jsonb)"
      }
    ] ++
      Enum.flat_map(kinds(), fn {kind, select, _rollup} -> minute_tier(kind, select) end) ++
      Enum.flat_map(kinds(), fn {kind, _select, rollup} -> hour_tier(kind, rollup) end)
  end

  # Each kind of view: its 1-minute query over readings, and its 1-hour
  # rollup of the 1-minute view. All 1-minute views come first, so the
  # migration's down drops the 1-hour views before their sources.
  defp kinds do
    [
      {:reading_numbers, numbers_1m(), number_rollup("idx")},
      {:reading_states, states_1m(), state_rollup("idx, state")},
      {:reading_member_numbers, member_numbers_1m(), number_rollup("member, idx")},
      {:reading_member_states, member_states_1m(), state_rollup("member, idx, state")}
    ]
  end

  @doc "The names of the views, 1-minute views first."
  def views do
    for tier <- ["1m", "1h"],
        kind <- ~w(reading_numbers reading_states reading_member_numbers reading_member_states),
        do: "#{kind}_#{tier}"
  end

  # The 1-minute view over readings with its columnstore, and the 1-hour view
  # rolled up from it, each with a refresh policy. Policies process the whole
  # range (start_offset NULL), oldest first, and as many batches per run as
  # are pending: see design decision 7 of add-reading-aggregates.
  # statement names, built from this module's constants at compile time
  # sobelow_skip ["DOS.BinToAtom"]
  defp minute_tier(kind, select) do
    minute = :"#{kind}_1m"

    view(minute, select) ++
      [
        %{
          name: :"#{minute}_columnstore",
          up: """
          ALTER MATERIALIZED VIEW #{minute} SET (
            timescaledb.enable_columnstore = true,
            timescaledb.segmentby = 'parameter_id',
            timescaledb.orderby = 'bucket'
          )
          """,
          # dropping the view drops its columnstore; turning it off would fail
          # while compressed chunks exist
          down: "SELECT 1"
        },
        %{
          name: :"#{minute}_columnstore_policy",
          up: "CALL add_columnstore_policy('#{minute}', after => INTERVAL '2 days')",
          down: "CALL remove_columnstore_policy('#{minute}')"
        },
        policy(minute, "1 minute", "1 minute", @minute_batch)
      ]
  end

  # statement names, built from this module's constants at compile time
  # sobelow_skip ["DOS.BinToAtom"]
  defp hour_tier(kind, rollup) do
    hour = :"#{kind}_1h"

    view(hour, String.replace(rollup, "$source", "#{kind}_1m")) ++
      [policy(hour, "1 hour", "15 minutes", @hour_batch)]
  end

  # statement names, built from this module's constants at compile time
  # sobelow_skip ["DOS.BinToAtom"]
  defp policy(view, end_offset, schedule, batch) do
    %{
      name: :"#{view}_policy",
      up: """
      SELECT add_continuous_aggregate_policy('#{view}',
        start_offset => NULL,
        end_offset => INTERVAL '#{end_offset}',
        schedule_interval => INTERVAL '#{schedule}',
        buckets_per_batch => #{batch},
        refresh_newest_first => false
      )
      """,
      down: "SELECT remove_continuous_aggregate_policy('#{view}')"
    }
  end

  # The 1-hour rollups (design decision 5). `count` is cast back to bigint,
  # since sum(bigint) is numeric. The bucket is grouped by its expression:
  # `bucket` alone would be the 1-minute column.
  defp number_rollup(keys) do
    """
    SELECT
      parameter_id,
      time_bucket(INTERVAL '1 hour', bucket) AS bucket,
      #{keys},
      min(lo) AS lo,
      max(hi) AS hi,
      sum(sum) AS sum,
      sum(count)::bigint AS count,
      min(first_key) AS first_key,
      max(last_key) AS last_key
    FROM $source
    GROUP BY parameter_id, time_bucket(INTERVAL '1 hour', bucket), #{keys}
    """
  end

  defp state_rollup(keys) do
    """
    SELECT
      parameter_id,
      time_bucket(INTERVAL '1 hour', bucket) AS bucket,
      #{keys},
      min(first_at) AS first_at,
      max(last_at) AS last_at,
      sum(count)::bigint AS count
    FROM $source
    GROUP BY parameter_id, time_bucket(INTERVAL '1 hour', bucket), #{keys}
    """
  end

  # A view, created empty, and its index on (parameter_id, bucket). The
  # group indexes TimescaleDB would add are off: the only one it would add
  # besides that, on (idx, bucket), no query uses.
  # statement names, built from this module's constants at compile time
  # sobelow_skip ["DOS.BinToAtom"]
  defp view(name, select) do
    [
      %{
        name: name,
        up: """
        CREATE MATERIALIZED VIEW #{name}
        WITH (
          timescaledb.continuous,
          timescaledb.materialized_only = true,
          timescaledb.create_group_indexes = false
        ) AS
        #{select}
        WITH NO DATA
        """,
        down: "DROP MATERIALIZED VIEW #{name}"
      },
      %{
        name: :"#{name}_index",
        up: "CREATE INDEX #{name}_parameter_id_bucket_index ON #{name} (parameter_id, bucket)",
        # the index is on the view's materialization hypertable, in
        # _timescaledb_internal, and goes with the view
        down: "SELECT 1"
      }
    ]
  end

  # Unpacks the direct members of a struct or tuple reading: one row per
  # member value, with `idx` 1 for a scalar member, 1.. for the elements of an
  # array member, and 0 (type `length`) for an array member's length. `type`
  # is the declared (element) type. Members of any other type, members the
  # datainfo doesn't declare, and readings or members of the wrong JSON shape
  # yield nothing. An array member yields nothing either unless every element
  # fits its type, as a top-level array that doesn't is kept as JSON and not
  # aggregated (see Reading.Storage). Scalar members are checked by the views.
  #
  # One SELECT, not STRICT, so Postgres can inline it into the view's query.
  # The argument is not called `value`: `jsonb_each` and
  # `jsonb_array_elements` have a `value` column that would shadow it. Every
  # call that fails on the wrong JSON type is inside a CASE that checks it
  # first, since Postgres may evaluate WHERE conditions in any order.
  defp member_values_function do
    array_ok = """
    CASE WHEN m.di ->> 'type' = 'array'
          AND m.di -> 'members' ->> 'type' IN #{@element_types}
          AND jsonb_typeof(m.val) = 'array'
        THEN NOT EXISTS (
          SELECT 1 FROM jsonb_array_elements(m.val) AS x(e)
          WHERE NOT #{fits("m.di -> 'members' ->> 'type'", "x.e")}
        )
        ELSE false
      END\
    """

    """
    CREATE FUNCTION reading_member_values(reading jsonb, datainfo jsonb)
    RETURNS TABLE(member text, idx int, type text, v jsonb)
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $fn$
      SELECT m.member, e.idx, e.type, e.v
      FROM (
        SELECT s.key AS member, s.value AS val, datainfo -> 'members' -> s.key AS di
        FROM jsonb_each(
          CASE WHEN datainfo ->> 'type' = 'struct' AND jsonb_typeof(reading) = 'object'
            THEN reading ELSE '{}'::jsonb END
        ) AS s
        UNION ALL
        SELECT (t.ord - 1)::text, t.val, datainfo -> 'members' -> (t.ord - 1)::int
        FROM jsonb_array_elements(
          CASE WHEN datainfo ->> 'type' = 'tuple' AND jsonb_typeof(reading) = 'array'
            THEN reading ELSE '[]'::jsonb END
        ) WITH ORDINALITY AS t(val, ord)
      ) AS m
      CROSS JOIN LATERAL (SELECT #{array_ok} AS array_ok OFFSET 0) AS k
      CROSS JOIN LATERAL (
        SELECT 1 AS idx, m.di ->> 'type' AS type, m.val AS v
        WHERE m.di ->> 'type' IN #{@element_types}
        UNION ALL
        SELECT 0, 'length',
          to_jsonb(CASE WHEN jsonb_typeof(m.val) = 'array' THEN jsonb_array_length(m.val) END)
        WHERE k.array_ok
        UNION ALL
        SELECT a.ord::int, m.di -> 'members' ->> 'type', a.val
        FROM jsonb_array_elements(
          CASE WHEN k.array_ok THEN m.val ELSE '[]'::jsonb END
        ) WITH ORDINALITY AS a(val, ord)
      ) AS e
    $fn$
    """
  end

  # Whether the JSON value `v` fits the declared type `type` (both SQL), as
  # Reading.Storage decides for a top-level value: a double within float8, an
  # int, scaled or enum a whole number within bigint, a bool a boolean. A
  # whole-number float counts as an integer: once in jsonb it can't reliably
  # be told from one (Jason writes 1000.0 as 1.0e3), unlike a top-level value, whose
  # Elixir type Reading.Storage sees.
  defp fits(type, v) do
    """
    CASE
        WHEN jsonb_typeof(#{v}) = 'number' THEN
          CASE
            WHEN #{type} = 'double' THEN
              abs(#{v}::numeric) = 0
                OR (abs(#{v}::numeric) > #{@float8_min}
                  AND abs(#{v}::numeric) <= #{@float8_max})
            WHEN #{type} IN ('int','scaled','enum') THEN
              CASE WHEN #{v}::numeric = trunc(#{v}::numeric)
                THEN #{v}::numeric >= -9223372036854775808 AND #{v}::numeric < 9223372036854775808
                ELSE false
              END
            ELSE false
          END
        WHEN jsonb_typeof(#{v}) = 'boolean' THEN #{type} = 'bool'
        ELSE false
      END\
    """
  end

  # Numbers of double, int and scaled parameters and arrays of them, and the
  # length (idx 0) of every aggregated array. `e.elements` is one array per
  # reading: the scalar alone (idx 1), or the length followed by the
  # elements (idx 0..). The length comes from the typed array columns only,
  # so a reading kept as JSON gets no length, and NULLs fail the range guard.
  defp numbers_1m do
    """
    SELECT
      r.parameter_id,
      time_bucket(INTERVAL '1 minute', r."timestamp") AS bucket,
      (u.ord - CASE WHEN p.datainfo ->> 'type' = 'array' THEN 1 ELSE 0 END)::int AS idx,
      #{number_aggregates("u.v", "r.id")}
    FROM readings r
    JOIN parameters p ON p.id = r.parameter_id
    CROSS JOIN LATERAL unnest(
      CASE
        WHEN p.datainfo ->> 'type' IN #{@number_types}
          THEN ARRAY[coalesce(r.value_float, r.value_int::float8)]
        WHEN p.datainfo -> 'members' ->> 'type' IN #{@number_types}
          THEN ARRAY[coalesce(cardinality(r.value_float_array), cardinality(r.value_int_array))::float8]
            || coalesce(r.value_float_array, r.value_int_array::float8[])
        ELSE ARRAY[coalesce(cardinality(r.value_int_array), cardinality(r.value_bool_array))::float8]
      END
    ) WITH ORDINALITY AS u(v, ord)
    WHERE (
        p.datainfo ->> 'type' IN #{@number_types}
        OR (p.datainfo ->> 'type' = 'array' AND p.datainfo -> 'members' ->> 'type' IN #{@element_types})
      )
      AND abs(u.v) < 1e290
    GROUP BY r.parameter_id, bucket, idx
    """
  end

  # States of enum and bool parameters and arrays of them: one row per state
  # that occurs. Enums come from the int columns and bools from the bool
  # columns, unnested side by side; a bool becomes 0 or 1, and a NULL (a
  # reading kept as JSON) stays NULL and is dropped.
  defp states_1m do
    state = "coalesce(u.i, CASE WHEN u.b THEN 1 WHEN NOT u.b THEN 0 END)"

    """
    SELECT
      r.parameter_id,
      time_bucket(INTERVAL '1 minute', r."timestamp") AS bucket,
      u.ord::int AS idx,
      #{state} AS state,
      #{state_aggregates()}
    FROM readings r
    JOIN parameters p ON p.id = r.parameter_id
    CROSS JOIN LATERAL unnest(
      CASE
        WHEN p.datainfo ->> 'type' = 'enum' THEN ARRAY[r.value_int]
        WHEN p.datainfo ->> 'type' = 'array' AND p.datainfo -> 'members' ->> 'type' = 'enum'
          THEN r.value_int_array
      END,
      CASE
        WHEN p.datainfo ->> 'type' = 'bool' THEN ARRAY[r.value_bool]
        WHEN p.datainfo ->> 'type' = 'array' AND p.datainfo -> 'members' ->> 'type' = 'bool'
          THEN r.value_bool_array
      END
    ) WITH ORDINALITY AS u(i, b, ord)
    WHERE (
        p.datainfo ->> 'type' IN #{@state_types}
        OR (p.datainfo ->> 'type' = 'array' AND p.datainfo -> 'members' ->> 'type' IN #{@state_types})
      )
      AND #{state} IS NOT NULL
    GROUP BY r.parameter_id, bucket, idx, state
    """
  end

  # Number members of structs and tuples, and the length (idx 0) of their
  # array members.
  defp member_numbers_1m do
    """
    SELECT
      r.parameter_id,
      time_bucket(INTERVAL '1 minute', r."timestamp") AS bucket,
      m.member,
      m.idx,
      #{number_aggregates(member_number(), "r.id")}
    FROM readings r
    JOIN parameters p ON p.id = r.parameter_id
    CROSS JOIN LATERAL reading_member_values(r.value_json -> 'value', p.datainfo) AS m
    WHERE p.datainfo ->> 'type' IN ('struct','tuple')
      AND NOT r.value_json ? 'type'
      AND m.type IN ('double','int','scaled','length')
      AND #{member_number()} IS NOT NULL
    GROUP BY r.parameter_id, bucket, m.member, m.idx
    """
  end

  # Enum and bool members of structs and tuples.
  defp member_states_1m do
    """
    SELECT
      r.parameter_id,
      time_bucket(INTERVAL '1 minute', r."timestamp") AS bucket,
      m.member,
      m.idx,
      #{member_state()} AS state,
      #{state_aggregates()}
    FROM readings r
    JOIN parameters p ON p.id = r.parameter_id
    CROSS JOIN LATERAL reading_member_values(r.value_json -> 'value', p.datainfo) AS m
    WHERE p.datainfo ->> 'type' IN ('struct','tuple')
      AND NOT r.value_json ? 'type'
      AND m.type IN #{@state_types}
      AND #{member_state()} IS NOT NULL
    GROUP BY r.parameter_id, bucket, m.member, m.idx, state
    """
  end

  # A member's number, or NULL. Every cast comes after the checks that make
  # it safe, in nested CASEs, because Postgres doesn't guarantee the order in
  # which AND conditions are evaluated. JSON holds numbers float8 can't, such
  # as 1e400 and 1e-400, so the range is checked as numeric first; ints and
  # scaled must be whole numbers within bigint (see fits/2).
  defp member_number do
    """
    CASE WHEN jsonb_typeof(m.v) = 'number' THEN
        CASE WHEN abs(m.v::numeric) < 1e290
            AND (m.v::numeric = 0 OR abs(m.v::numeric) > #{@float8_min})
            AND (m.type NOT IN ('int','scaled')
              OR (m.v::numeric = trunc(m.v::numeric)
                AND m.v::numeric >= -9223372036854775808
                AND m.v::numeric < 9223372036854775808))
          THEN m.v::numeric::float8 END
      END\
    """
  end

  # A member's state, or NULL: an enum must be a whole number within bigint,
  # a bool a JSON boolean.
  defp member_state do
    """
    CASE
        WHEN m.type = 'enum' AND jsonb_typeof(m.v) = 'number' THEN
          CASE WHEN m.v::numeric = trunc(m.v::numeric)
              AND m.v::numeric >= -9223372036854775808
              AND m.v::numeric < 9223372036854775808
            THEN m.v::numeric::bigint END
        WHEN m.type = 'bool' AND jsonb_typeof(m.v) = 'boolean' THEN
          CASE WHEN m.v = 'true'::jsonb THEN 1::bigint ELSE 0::bigint END
      END\
    """
  end

  defp state_aggregates do
    """
    min(r."timestamp") AS first_at,
      max(r."timestamp") AS last_at,
      count(*) AS count
    """
  end

  # The number columns: extremes as [value, time, id] keys and first and last
  # as [time, id, value] keys, so ties go to the earliest reading and then the
  # lower id (design decision 5), and the float8 sum and count for the mean.
  defp number_aggregates(v, id) do
    """
    min(ARRAY[#{v}, #{@t}, #{id}::float8]) AS lo,
      max(ARRAY[#{v}, -#{@t}, -#{id}::float8]) AS hi,
      sum(#{v}) AS sum,
      count(*) AS count,
      min(ARRAY[#{@t}, #{id}::float8, #{v}]) AS first_key,
      max(ARRAY[#{@t}, #{id}::float8, #{v}]) AS last_key
    """
  end
end
