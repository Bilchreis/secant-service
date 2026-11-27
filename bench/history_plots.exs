# Benchmarks and profiles the historical plots on long recordings: what the
# server does from the database query to the JSON it pushes to the browser.
#
#     MIX_ENV=test mix run --no-start bench/history_plots.exs
#
# Runs in the test env (consolidated protocols, no NodeManager, no node
# discovery) against its own database, `secant_service_bench` on the test
# env's Postgres, so neither the dev nor the test database is touched. The
# first run creates and migrates that database and seeds one recording per
# type; later runs reuse it (a different size seeds another recording).
#
# Per type (double, int, array of doubles, struct) it measures:
#
#   * initial load  `PlotDB.init(module, :historical)` + JSON of the pushed
#                   option, as the history view does when it opens a plot
#   * db: window    `SecNodes.history_window!` over the whole recording,
#                   the thinning query alone
#   * build option  the chart option from an already loaded window (what
#                   `PlotDB.Readable.plot/2` does after its fetch)
#   * encode        JSON of the initial load's option
#   * zoom 10%      a zoom into the middle tenth of the recording, as the
#                   `fetch-chart-window` event does: window, trace updates, JSON
#   * zoom 30 min   the same for a window short enough to come back raw
#
# Before benchee, a breakdown table shows for each step the database time
# (from the Repo's telemetry), the time spent in Elixir, the JSON time, the
# payload size and the number of readings sent.
#
# Before that, an aggregates section refreshes the continuous aggregates over
# the readings (`SecantService.SecNodes.Reading.AggregateViews`), and times
# `PlotDB.Aggregates.numbers/4` at 15-minute buckets over the recording for
# the double, array and struct, and for an array of BENCH_WIDE_LEN elements
# with a reading a minute (a 1-minute view's size depends on its buckets and
# elements, not on how often the parameter reads). It reports each view's size
# and the timings with the 1-minute views uncompressed and compressed. The
# views' policy jobs are paused, so the bench refreshes them itself.
#
# Environment variables (defaults in brackets):
#
#   BENCH_HOURS        length of each recording [72]
#   BENCH_INTERVAL_MS  time between readings [1000]
#   BENCH_ARRAY_LEN    elements per array reading, at most 100 [50]
#   BENCH_STORAGE      raw | compressed | both: chunks as rows or in
#                      TimescaleDB's columnstore [both]
#   BENCH_DTYPES       comma separated subset of double,int,array,struct [all]
#   BENCH_JOBS         comma separated substrings of the job names [all]
#   BENCH_TIME         seconds per job [5]
#   BENCH_WARMUP       warmup seconds per job [1]
#   BENCH_MEMORY_TIME  seconds of memory measurement per job, 0 for none [1]
#   BENCH_PROFILE      eprof | fprof | cprof | tprof: profile each job after
#                      measuring it (only this process, so the database
#                      time shows as waiting) [none]
#   BENCH_EXPLAIN      1 prints EXPLAIN (ANALYZE, BUFFERS) of the slowest
#                      query of each step [0]
#   BENCH_SAVE         path prefix to save the results for comparison, e.g.
#                      bench/results/main [none]
#   BENCH_LOAD         path prefix of saved results to compare with [none]
#   BENCH_DB           database name [secant_service_bench]
#   BENCH_RESEED       1 seeds this size's recording again [0]
#   BENCH_AGGREGATES   0 skips the aggregates section [1]
#   BENCH_PLOTS        0 skips the plot breakdown and benchee [1]
#   BENCH_WIDE_LEN     elements of the aggregates section's wide array [1000]
#
# The aggregates section ends with envelope windows: `History.window/4`
# with `envelope: true` (bucket means and bands from the aggregates, head
# and tail thinned) against the same window thinned as today, for the
# double and the array over the whole recording and for the double over
# 4 h in its middle. It raises if an envelope window comes back without
# band rows, so a stale or empty view can't pass for a fast one.

defmodule HistoryBench.Config do
  @moduledoc false

  def get do
    %{
      hours: int("BENCH_HOURS", 72),
      interval_ms: int("BENCH_INTERVAL_MS", 1000),
      array_len: int("BENCH_ARRAY_LEN", 50),
      storage: storage(System.get_env("BENCH_STORAGE", "both")),
      dtypes: list("BENCH_DTYPES", ~w(double int array struct)),
      jobs: list("BENCH_JOBS", nil),
      time: int("BENCH_TIME", 5),
      warmup: int("BENCH_WARMUP", 1),
      memory_time: int("BENCH_MEMORY_TIME", 1),
      profile: profile(System.get_env("BENCH_PROFILE")),
      explain?: System.get_env("BENCH_EXPLAIN") == "1",
      save: System.get_env("BENCH_SAVE"),
      load: System.get_env("BENCH_LOAD"),
      database: System.get_env("BENCH_DB", "secant_service_bench"),
      reseed?: System.get_env("BENCH_RESEED") == "1",
      aggregates?: System.get_env("BENCH_AGGREGATES", "1") != "0",
      plots?: System.get_env("BENCH_PLOTS", "1") != "0",
      wide_len: int("BENCH_WIDE_LEN", 1000)
    }
  end

  defp int(name, default), do: name |> System.get_env(to_string(default)) |> String.to_integer()

  defp list(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp storage("both"), do: [:raw, :compressed]
  defp storage("raw"), do: [:raw]
  defp storage("compressed"), do: [:compressed]

  defp profile(nil), do: false
  defp profile(""), do: false
  defp profile(name) when name in ~w(eprof fprof cprof tprof), do: String.to_atom(name)
end

defmodule HistoryBench.Setup do
  @moduledoc false
  # The bench database and its recordings.

  alias SecantService.Repo
  alias SecantService.SecNodes.Module

  require Ash.Query

  @struct_datainfo %{
    "type" => "struct",
    "members" => %{
      "temperature" => %{"type" => "double", "unit" => "K"},
      "pressure" => %{"type" => "double", "unit" => "mbar"},
      "flow" => %{"type" => "double", "unit" => "ml/min"},
      "mode" => %{
        "type" => "enum",
        "members" => %{"idle" => 0, "ramp" => 1, "hold" => 2, "cool" => 3}
      },
      "count" => %{"type" => "int", "min" => 0, "max" => 1000}
    }
  }

  # rows per INSERT, so seeding shows progress and no statement runs forever
  @batch 100_000

  def start(config) do
    repo_config =
      :secant_service
      |> Application.fetch_env!(Repo)
      |> Keyword.merge(
        database: config.database,
        # the pool the app runs on in production, not the test sandbox
        pool: DBConnection.ConnectionPool,
        pool_size: 10,
        # the aggregates section reads a 1000-element array's 288,000 buckets
        timeout: 120_000,
        log: false
      )

    Application.put_env(:secant_service, Repo, repo_config)

    case Repo.__adapter__().storage_up(repo_config) do
      :ok -> IO.puts("Created database #{config.database}")
      {:error, :already_up} -> :ok
      {:error, reason} -> raise "could not create #{config.database}: #{inspect(reason)}"
    end

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Repo, &Ecto.Migrator.run(&1, :up, all: true, log: false))

    {:ok, _} = Application.ensure_all_started(:secant_service)
    Logger.configure(level: :warning)

    # the columnstore policy would compress chunks in the background, in the
    # middle of a run; the bench sets the storage itself
    Repo.query!("CALL remove_columnstore_policy('readings', if_exists => true)")

    # the same for the aggregates' refresh and columnstore jobs
    Repo.query!("""
    SELECT (alter_job(j.job_id, scheduled => false)).job_id
    FROM timescaledb_information.jobs j
    JOIN timescaledb_information.continuous_aggregates c
      ON c.view_schema = j.hypertable_schema AND c.view_name = j.hypertable_name
    WHERE j.scheduled
    """)
  end

  def datainfo("double"), do: %{"type" => "double", "unit" => "K"}
  def datainfo("int"), do: %{"type" => "int", "min" => 0, "max" => 100}

  def datainfo("array"),
    do: %{"type" => "array", "members" => %{"type" => "double", "unit" => "V"}, "maxlen" => 100}

  def datainfo("struct"), do: @struct_datainfo

  @doc "The recording's modules by type, seeded unless already there."
  def recording(config) do
    readings = div(config.hours * 3_600_000, config.interval_ms)

    equipment_id =
      "history_bench_#{config.hours}h_#{config.interval_ms}ms_a#{config.array_len}"

    node =
      SecantService.SecNodes.SecNode
      |> Ash.Query.filter(equipment_id == ^equipment_id)
      |> Ash.read_one!()

    node = node || create_node(equipment_id, config)
    t0 = node.inserted_at

    modules =
      Module
      |> Ash.Query.filter(sec_node_id == ^node.uuid)
      |> Ash.Query.load(:parameters)
      |> Ash.read!()
      |> Map.new(&{&1.name, &1})

    for dtype <- config.dtypes, into: %{} do
      module = Map.fetch!(modules, dtype)
      [param] = module.parameters
      seed(dtype, param, t0, readings, config)
      {dtype, %{module: module, param: param, t0: t0, readings: readings}}
    end
  end

  defp create_node(equipment_id, config) do
    node = Ash.Generator.generate(SecantService.Generators.sec_node(equipment_id: equipment_id))

    for dtype <- ~w(double int array struct) do
      module =
        Ash.Generator.generate(
          SecantService.Generators.sec_module(
            sec_node_id: node.uuid,
            name: dtype,
            interface_classes: ["Readable"]
          )
        )

      Ash.Generator.generate(
        SecantService.Generators.parameter(module_id: module.id, datainfo: datainfo(dtype))
      )
    end

    # the session starts where the recording does (see `plot_start_ms/1`),
    # ending about now
    span_ms = config.hours * 3_600_000

    t0 =
      DateTime.utc_now()
      |> DateTime.add(-span_ms, :millisecond)
      |> DateTime.truncate(:second)

    Repo.query!("UPDATE sec_nodes SET inserted_at = $1 WHERE uuid = $2", [
      DateTime.to_naive(t0),
      Ecto.UUID.dump!(node.uuid)
    ])

    %{node | inserted_at: t0}
  end

  defp seed(dtype, param, t0, readings, config) do
    %{rows: [[stored]]} =
      Repo.query!("SELECT count(*) FROM readings WHERE parameter_id = $1", [param.id])

    if stored != readings or config.reseed? do
      Repo.query!("DELETE FROM readings WHERE parameter_id = $1", [param.id], timeout: :infinity)
      IO.write("Seeding #{readings} #{dtype} readings ")
      {column, expr} = value_sql(dtype, config.array_len)

      sql = """
      INSERT INTO readings (parameter_id, timestamp, #{column}, qualifiers)
      SELECT $1, $2::timestamp + ($3::bigint * i) * interval '1 millisecond', #{expr}, '{}'::jsonb
      FROM generate_series($4::bigint, $5::bigint) AS i
      """

      for first <- 0..(readings - 1)//@batch do
        last = min(first + @batch, readings) - 1

        Repo.query!(
          sql,
          [param.id, DateTime.to_naive(t0), config.interval_ms, first, last],
          timeout: :infinity
        )

        IO.write(".")
      end

      Repo.query!("ANALYZE readings", [], timeout: :infinity)
      IO.puts(" done")
    end
  end

  @doc """
  An array of `config.wide_len` doubles with a reading a minute over the
  recording's span, on its own SEC node; seeded unless already there.
  """
  def wide_array(config) do
    equipment_id = "aggregates_bench_#{config.hours}h_wide#{config.wide_len}"
    readings = config.hours * 60

    node =
      SecantService.SecNodes.SecNode
      |> Ash.Query.filter(equipment_id == ^equipment_id)
      |> Ash.read_one!()

    {node, param} =
      case node do
        nil ->
          node =
            Ash.Generator.generate(SecantService.Generators.sec_node(equipment_id: equipment_id))

          module =
            Ash.Generator.generate(
              SecantService.Generators.sec_module(sec_node_id: node.uuid, name: "wide")
            )

          param =
            Ash.Generator.generate(
              SecantService.Generators.parameter(
                module_id: module.id,
                datainfo: %{
                  "type" => "array",
                  "members" => %{"type" => "double"},
                  "maxlen" => config.wide_len
                }
              )
            )

          # the recording ends about now, as in create_node/2
          t0 =
            DateTime.utc_now() |> DateTime.add(-config.hours, :hour) |> DateTime.truncate(:second)

          Repo.query!("UPDATE sec_nodes SET inserted_at = $1 WHERE uuid = $2", [
            DateTime.to_naive(t0),
            Ecto.UUID.dump!(node.uuid)
          ])

          {%{node | inserted_at: t0}, param}

        node ->
          [module] =
            Module
            |> Ash.Query.filter(sec_node_id == ^node.uuid)
            |> Ash.Query.load(:parameters)
            |> Ash.read!()

          {node, hd(module.parameters)}
      end

    t0 = node.inserted_at
    seed_wide(param, t0, readings, config)
    %{param: param, t0: t0, readings: readings}
  end

  defp seed_wide(param, t0, readings, config) do
    %{rows: [[stored]]} =
      Repo.query!("SELECT count(*) FROM readings WHERE parameter_id = $1", [param.id])

    if stored != readings or config.reseed? do
      Repo.query!("DELETE FROM readings WHERE parameter_id = $1", [param.id], timeout: :infinity)
      IO.write("Seeding #{readings} readings of a #{config.wide_len}-element array ... ")

      Repo.query!(
        """
        INSERT INTO readings (parameter_id, timestamp, value_float_array, qualifiers)
        SELECT $1, $2::timestamp + i * interval '1 minute',
          ARRAY(SELECT sin(i / 60.0 + k / 50.0) * 10 + random() FROM generate_series(1, $3) AS k),
          '{}'::jsonb
        FROM generate_series(0, $4::bigint - 1) AS i
        """,
        [param.id, DateTime.to_naive(t0), config.wide_len, readings],
        timeout: :infinity
      )

      IO.puts("done")
    end
  end

  # slow waves with noise, so the thinning has extremes to keep; i is the
  # reading's index
  defp value_sql("double", _len), do: {"value_float", "sin(i / 600.0) * 10 + random()"}

  defp value_sql("int", _len),
    do: {"value_int", "((i / 30) % 90 + floor(random() * 10))::bigint"}

  defp value_sql("array", len) do
    {"value_float_array",
     "ARRAY(SELECT sin(i / 600.0 + k / 5.0) * 10 + random() FROM generate_series(1, #{len}) AS k)"}
  end

  # wrapped in "value", as the app stores a struct (see Reading.Storage)
  defp value_sql("struct", _len) do
    {"value_json",
     """
     jsonb_build_object('value', jsonb_build_object(
       'temperature', sin(i / 600.0) * 10 + 290 + random(),
       'pressure', 1000 + cos(i / 900.0) * 50 + random(),
       'flow', random() * 5,
       'mode', (i / 1800) % 4,
       'count', i % 1000
     ))
     """}
  end

  @doc "Puts every chunk of the readings in row storage or in the columnstore."
  def set_storage(storage) do
    IO.write("Moving the readings to #{storage} storage ... ")

    sql =
      case storage do
        :raw ->
          "SELECT decompress_chunk(c, if_compressed => true) FROM show_chunks('readings') c"

        :compressed ->
          "SELECT compress_chunk(c, if_not_compressed => true) FROM show_chunks('readings') c"
      end

    Repo.query!(sql, [], timeout: :infinity)
    Repo.query!("ANALYZE readings", [], timeout: :infinity)
    IO.puts("done")
  end
end

defmodule HistoryBench.Steps do
  @moduledoc false
  # What the server does per step, as `SecantServiceWeb.HistoryDB` does it.

  alias SecantService.PlotDB
  alias SecantService.PlotDB.DTypePlot
  alias SecantService.PlotDB.DTypes.ArrayHeatmap
  alias SecantService.PlotDB.DTypes.Struct
  alias SecantService.PlotDB.History
  alias SecantService.SecNodes

  @json Phoenix.json_library()

  # the history view opens a plot: `PlotDB.init/2` in `start_async`, then the
  # option goes out with `push_event(socket, "echarts-data-…", %{option: …})`
  def initial_load(%{module: module}) do
    plot = PlotDB.init(module, :historical)
    @json.encode_to_iodata!(%{option: plot.option})
  end

  def plot(%{module: module}), do: PlotDB.init(module, :historical)

  def encode(plot), do: @json.encode_to_iodata!(%{option: plot.option})

  # the thinning query over the whole recording, as `Builders.fetch_param_data/2`
  # runs it
  def window(%{param: param, from_ms: from_ms}),
    do: SecNodes.history_window!(param.id, from_ms, nil)

  # `PlotDB.Readable.plot/2` after its fetch (the initial load also holds the
  # last reading before the session start; there is none here)
  def build_option(%{param: param}, %{values: val, timestamps: ts}) do
    datainfo = param.datainfo

    case DTypePlot.for_datainfo(datainfo) do
      ArrayHeatmap ->
        ArrayHeatmap.heatmap_option(
          [ArrayHeatmap.heatmap_series(ts, val)],
          ArrayHeatmap.max_len(val),
          ArrayHeatmap.unit(datainfo),
          :historical,
          name: param.name
        )

      Struct ->
        Struct.build_struct_option("value", ts, val, datainfo, :historical)

      dtype_mod ->
        series = dtype_mod.build_series("value", ts, val, datainfo)
        dtype_mod.build_option(series, datainfo, datainfo["unit"], :historical, [])
    end
  end

  # the `fetch-chart-window` event of a zoomed chart; the window lies after
  # the session start, so no held reading is added
  def zoom(%{param: param, plot: plot}, {from_ms, to_ms}) do
    window = SecNodes.history_window!(param.id, from_ms, to_ms)
    datapoints = Enum.zip(window.values, window.timestamps)
    updates = PlotDB.get_trace_updates_batch(plot, datapoints, param.name)

    History.coarsest([window])
    |> Map.merge(updates)
    |> Map.merge(%{from: from_ms, to: to_ms, req: 1})
    |> @json.encode_to_iodata!()
  end
end

defmodule HistoryBench.Aggregates do
  @moduledoc false
  # The continuous aggregates: refresh, sizes, and reading them.

  alias HistoryBench.Breakdown
  alias SecantService.PlotDB.Aggregates
  alias SecantService.PlotDB.History
  alias SecantService.Repo
  alias SecantService.SecNodes.Reading.AggregateViews

  @bucket_ms 15 * 60_000

  def run(config, recording, wide) do
    IO.puts("\n== Aggregates ==\n")

    for view <- AggregateViews.views() do
      {us, _} =
        :timer.tc(fn ->
          # batched as the policies are: a manual refresh otherwise runs in
          # 10-bucket batches, newest first, and takes many times as long
          Repo.query!(
            "CALL refresh_continuous_aggregate($1::text::regclass, NULL, NULL, options => $2)",
            [view, %{buckets_per_batch: 360, refresh_newest_first: false}],
            timeout: :infinity
          )
        end)

      IO.puts("refreshed #{String.pad_trailing(view, 26)} #{ms(us)} ms")
    end

    params =
      [{"wide", wide} | Enum.map(~w(double array struct), &{&1, recording[&1]})]
      |> Enum.reject(fn {_dtype, rec} -> rec == nil end)

    # an earlier run may have left them compressed
    set_minute_storage("decompress_chunk(c, if_compressed => true)")
    uncompressed = reads(params, config)
    before = sizes()

    IO.write("\nCompressing the 1-minute views ... ")
    set_minute_storage("compress_chunk(c, if_not_compressed => true)")
    IO.puts("done")
    compressed = reads(params, config)
    after_ = sizes()

    IO.puts("\nview                        rows        uncompressed  compressed")

    for view <- AggregateViews.views() do
      {rows, size} = before[view]
      {_rows, compressed_size} = after_[view]

      IO.puts(
        "#{String.pad_trailing(view, 26)}  #{String.pad_leading(to_string(rows), 10)}  " <>
          "#{String.pad_leading(mb(size), 12)}  #{String.pad_leading(mb(compressed_size), 10)}"
      )
    end

    envelopes(config, params)

    IO.puts("\nnumbers/4, 15-minute buckets over #{config.hours} h (median of 5 runs)")
    IO.puts("type     buckets  uncompressed_ms  compressed_ms  queries")

    for {{dtype, n, u}, {_, _, c}} <- Enum.zip(uncompressed, compressed) do
      IO.puts(
        "#{String.pad_trailing(dtype, 7)}  #{String.pad_leading(to_string(n), 7)}  " <>
          "#{String.pad_leading(ms(u.wall_us), 15)}  #{String.pad_leading(ms(c.wall_us), 13)}  " <>
          "#{String.pad_leading(to_string(u.queries), 7)}"
      )
    end
  end

  # compresses or decompresses the 1-minute views, then vacuums them, as
  # autovacuum would, so reads don't pay for the rows' first visibility check
  defp set_minute_storage(call) do
    %{rows: views} =
      Repo.query!("""
      SELECT view_name, format('%I.%I', materialization_hypertable_schema,
        materialization_hypertable_name)
      FROM timescaledb_information.continuous_aggregates WHERE view_name LIKE '%\\_1m'
      """)

    for [view, hypertable] <- views do
      Repo.query!("SELECT #{call} FROM show_chunks($1::text::regclass) c", [view],
        timeout: :infinity
      )

      Repo.query!("VACUUM ANALYZE #{hypertable}", [], timeout: :infinity)
    end
  end

  # numbers/4 for each parameter over its recording
  defp reads(params, config) do
    for {dtype, rec} <- params do
      from = DateTime.to_unix(rec.t0, :millisecond)
      to = from + config.hours * 3_600_000

      {:ok, %{buckets: buckets}} = Aggregates.numbers(rec.param, from, to, @bucket_ms)

      timing =
        Breakdown.measure(fn ->
          _ = Aggregates.numbers(rec.param, from, to, @bucket_ms)
          nil
        end)

      {dtype, length(buckets), timing}
    end
  end

  # Envelope windows against today's thinning, with the 1-minute views as
  # they are now (compressed by run/3 before this).
  defp envelopes(config, params) do
    span_ms = config.hours * 3_600_000

    cases =
      for {dtype, rec} <- params, dtype in ~w(double array) do
        from = DateTime.to_unix(rec.t0, :millisecond)
        {"#{dtype} #{config.hours} h", rec.param, from, from + span_ms}
      end

    cases =
      case Enum.find(params, &(elem(&1, 0) == "double")) do
        {_, rec} ->
          mid = DateTime.to_unix(rec.t0, :millisecond) + div(span_ms, 2)
          cases ++ [{"double 4 h", rec.param, mid - 2 * 3_600_000, mid + 2 * 3_600_000}]

        nil ->
          cases
      end

    IO.puts("\nenvelope windows against today's thinning (median of 5 runs)")
    IO.puts("case             bucket  rows    envelope_ms  queries  thinned_ms  queries")

    for {name, param, from, to} <- cases do
      window = History.window(param, from, to, envelope: true)

      unless match?(%{envelope: %{rows: [_ | _]}}, window) do
        raise "#{name}: no envelope rows; are the aggregates refreshed over the recording?"
      end

      envelope =
        Breakdown.measure(fn -> History.window(param, from, to, envelope: true) && nil end)

      thinned = Breakdown.measure(fn -> History.window(param, from, to) && nil end)

      IO.puts(
        "#{String.pad_trailing(name, 15)}  #{String.pad_leading(to_string(div(window.bucket_ms, 60_000)) <> " min", 6)}  " <>
          "#{String.pad_leading(to_string(length(window.envelope.rows)), 6)}  " <>
          "#{String.pad_leading(ms(envelope.wall_us), 11)}  #{String.pad_leading(to_string(envelope.queries), 7)}  " <>
          "#{String.pad_leading(ms(thinned.wall_us), 10)}  #{String.pad_leading(to_string(thinned.queries), 7)}"
      )
    end
  end

  # rows and total size per view, from its materialization hypertable
  defp sizes do
    %{rows: rows} =
      Repo.query!("""
      SELECT c.view_name,
        hypertable_size(format('%I.%I', c.materialization_hypertable_schema,
          c.materialization_hypertable_name)::regclass)
      FROM timescaledb_information.continuous_aggregates c
      """)

    Map.new(rows, fn [view, size] ->
      %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{view}", [], timeout: :infinity)
      {view, {count, size}}
    end)
  end

  defp mb(bytes), do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1) <> " MB"
  defp ms(us), do: :erlang.float_to_binary(us / 1000, decimals: 1)
end

defmodule HistoryBench.Breakdown do
  @moduledoc false
  # Where a step's time goes: database (Repo telemetry), Elixir, JSON.

  alias SecantService.Repo

  @event [:secant_service, :repo, :query]
  @runs 5

  def attach do
    :ets.new(__MODULE__, [:named_table, :public, :duplicate_bag])

    :telemetry.attach(
      __MODULE__,
      @event,
      fn _event, measurements, meta, _ ->
        if :persistent_term.get(__MODULE__, false) do
          db_us =
            [:queue_time, :query_time, :decode_time]
            |> Enum.map(&Map.get(measurements, &1, 0))
            |> Enum.sum()
            |> System.convert_time_unit(:native, :microsecond)

          :ets.insert(__MODULE__, {self(), db_us, meta.query, meta.params})
        end
      end,
      nil
    )
  end

  @doc "Median over a few runs of `fun`, which returns the JSON payload (or nil)."
  def measure(fun) do
    runs =
      for _ <- 1..@runs do
        :ets.delete_all_objects(__MODULE__)
        :persistent_term.put(__MODULE__, true)
        {wall_us, payload} = :timer.tc(fun)
        :persistent_term.put(__MODULE__, false)
        queries = :ets.lookup(__MODULE__, self())

        %{
          wall_us: wall_us,
          db_us: queries |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
          queries: length(queries),
          slowest: Enum.max_by(queries, &elem(&1, 1), fn -> nil end),
          bytes: payload && IO.iodata_length(payload)
        }
      end

    runs |> Enum.sort_by(& &1.wall_us) |> Enum.at(div(@runs, 2))
  end

  def print(rows) do
    header = ~w(type step total_ms db_ms queries elixir_ms json_ms payload_kb readings)

    lines =
      Enum.map(rows, fn r ->
        [
          r.dtype,
          r.step,
          ms(r.wall_us),
          ms(r.db_us),
          to_string(r.queries),
          ms(r.wall_us - r.db_us - (r[:json_us] || 0)),
          (r[:json_us] && ms(r.json_us)) || "-",
          (r.bytes && :erlang.float_to_binary(r.bytes / 1024, decimals: 0)) || "-",
          to_string(r.readings)
        ]
      end)

    widths =
      [header | lines]
      |> Enum.zip_with(fn col -> col |> Enum.map(&String.length/1) |> Enum.max() end)

    for line <- [header | lines] do
      line
      |> Enum.zip(widths)
      |> Enum.with_index()
      |> Enum.map_join("  ", fn
        {{cell, w}, i} when i < 2 -> String.pad_trailing(cell, w)
        {{cell, w}, _} -> String.pad_leading(cell, w)
      end)
      |> IO.puts()
    end
  end

  def explain(%{slowest: {_pid, db_us, sql, params}, dtype: dtype, step: step}) do
    IO.puts("\n--- EXPLAIN #{dtype} / #{step} (slowest query, #{ms(db_us)} ms) ---")

    %{rows: rows} =
      Repo.query!("EXPLAIN (ANALYZE, BUFFERS) " <> sql, params, timeout: :infinity)

    Enum.each(rows, fn [line] -> IO.puts(line) end)
  end

  def explain(_row), do: :ok

  defp ms(us), do: :erlang.float_to_binary(us / 1000, decimals: 1)
end

# ------------------------------------------------------------------------------

saved = fn config, storage ->
  save =
    if config.save,
      do: [save: [path: "#{config.save}-#{storage}.benchee", tag: Path.basename(config.save)]],
      else: []

  load = if config.load, do: [load: "#{config.load}-#{storage}.benchee"], else: []
  save ++ load
end

alias HistoryBench.{Aggregates, Breakdown, Config, Setup, Steps}

config = Config.get()
Setup.start(config)
recording = Setup.recording(config)
Breakdown.attach()

span_ms = config.hours * 3_600_000

IO.puts("""

Recording: #{config.hours} h, a reading every #{config.interval_ms} ms \
(#{div(span_ms, config.interval_ms)} per type), arrays of #{config.array_len}
""")

if config.aggregates? do
  Aggregates.run(config, recording, Setup.wide_array(config))
end

for storage <- if(config.plots?, do: config.storage, else: []) do
  Setup.set_storage(storage)

  # what each step works on, loaded once
  inputs =
    Map.new(recording, fn {dtype, rec} ->
      from_ms = DateTime.to_unix(rec.t0, :millisecond)
      rec = Map.put(rec, :from_ms, from_ms)
      plot = Steps.plot(rec)
      window = Steps.window(rec)
      mid = from_ms + div(span_ms, 2)

      zooms = %{
        tenth: {mid - div(span_ms, 20), mid + div(span_ms, 20)},
        half_hour: {mid - 15 * 60_000, mid + 15 * 60_000}
      }

      {dtype, Map.merge(rec, %{plot: plot, window: window, zooms: zooms})}
    end)

  # -- breakdown ----------------------------------------------------------------

  IO.puts("\n== Breakdown, #{storage} storage (median of 5 runs) ==\n")

  rows =
    Enum.flat_map(config.dtypes, fn dtype ->
      input = inputs[dtype]
      load = Breakdown.measure(fn -> Steps.initial_load(input) end)
      json = Breakdown.measure(fn -> Steps.encode(input.plot) end)
      zoom_tenth = Breakdown.measure(fn -> Steps.zoom(input, input.zooms.tenth) end)
      zoom_half_hour = Breakdown.measure(fn -> Steps.zoom(input, input.zooms.half_hour) end)

      zoom_readings = fn {from, to} ->
        input.param.id
        |> SecantService.SecNodes.history_window!(from, to)
        |> Map.get(:values)
        |> length()
      end

      [
        Map.merge(load, %{
          dtype: dtype,
          step: "initial load",
          json_us: json.wall_us,
          readings: length(input.window.values)
        }),
        Map.merge(zoom_tenth, %{
          dtype: dtype,
          step: "zoom 10%",
          readings: zoom_readings.(input.zooms.tenth)
        }),
        Map.merge(zoom_half_hour, %{
          dtype: dtype,
          step: "zoom 30 min",
          readings: zoom_readings.(input.zooms.half_hour)
        })
      ]
    end)

  Breakdown.print(rows)
  IO.puts("\n(zoom rows: elixir_ms includes their JSON)")

  if config.explain?, do: Enum.each(rows, &Breakdown.explain/1)

  # -- benchee ------------------------------------------------------------------

  jobs =
    %{
      "initial load" => &Steps.initial_load/1,
      "db: window" => &Steps.window/1,
      "build option" => &Steps.build_option(&1, &1.window),
      "encode" => &Steps.encode(&1.plot),
      "zoom 10%" => &Steps.zoom(&1, &1.zooms.tenth),
      "zoom 30 min" => &Steps.zoom(&1, &1.zooms.half_hour)
    }
    |> Map.filter(fn {name, _} ->
      config.jobs == nil or Enum.any?(config.jobs, &String.contains?(name, &1))
    end)

  # a list keeps the inputs in the order given
  bench_inputs = Enum.map(config.dtypes, &{&1, inputs[&1]})

  Benchee.run(
    jobs,
    [
      title: "History plots, #{storage} storage",
      inputs: bench_inputs,
      warmup: config.warmup,
      time: config.time,
      memory_time: config.memory_time,
      profile_after: config.profile,
      formatters: [{Benchee.Formatters.Console, extended_statistics: false}]
    ] ++
      saved.(config, storage)
  )
end
