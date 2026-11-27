defmodule SecantService.PlotDB.HistoryTest do
  use SecantService.DataCase, async: false

  import Ecto.Query

  alias SecantService.SecNodes
  alias SecantService.SecNodes.Reading.Storage
  alias SecantService.PlotDB
  alias SecantService.PlotDB.Builders
  alias SecantService.PlotDB.History
  alias SecantService.PlotDB.History.Channels
  alias SecantService.Repo

  alias SecantService.SecNodes.Parameter

  @start ~U[2026-03-01 00:00:00.000000Z]

  # One reading per second from @start; `value_fun` maps the index to a value.
  defp insert_readings(parameter, count, value_fun) do
    readings =
      for i <- 0..(count - 1) do
        Storage.to_row(value_fun.(i), parameter, DateTime.add(@start, i, :second), %{})
      end

    %Ash.BulkResult{status: :success} = SecNodes.insert_readings(readings)
    :ok
  end

  defp ms(index), do: DateTime.to_unix(@start, :millisecond) + index * 1000

  defp points(window), do: Enum.zip(window.timestamps, window.values)

  defp fetch_historical(parameter) do
    {values, timestamps, _resolution} = Builders.fetch_param_window(parameter, :historical)
    {values, timestamps}
  end

  describe "thinnable?/1 and limits/1" do
    test "everything the plots draw is thinned out" do
      for datainfo <- [
            %{"type" => "double"},
            %{"type" => "int"},
            %{"type" => "scaled"},
            %{"type" => "enum", "members" => %{"a" => 0}},
            %{"type" => "array", "members" => %{"type" => "double"}},
            %{"type" => "struct", "members" => %{"flow" => %{"type" => "double"}}}
          ] do
        assert History.thinnable?(%Parameter{datainfo: datainfo}), inspect(datainfo)
      end

      for datainfo <- [
            %{"type" => "string"},
            %{"type" => "bool"},
            %{"type" => "array", "members" => %{"type" => "string"}},
            %{"type" => "struct", "members" => %{"name" => %{"type" => "string"}}}
          ] do
        refute History.thinnable?(%Parameter{datainfo: datainfo}), inspect(datainfo)
      end
    end

    test "an array length the node got wrong falls back to the default" do
      default = History.limits(%Parameter{datainfo: Map.delete(array_info(4), "maxlen")})

      for len <- [100.0, "100", 0, -3, nil] do
        datainfo = %{array_info(4) | "maxlen" => len}
        assert History.limits(%Parameter{datainfo: datainfo}) == default, inspect(len)
      end

      # a huge declared length only shrinks the budget: the safe direction
      assert History.limits(%Parameter{datainfo: array_info(1_000_000_000)}) == {50, 50}
      assert History.limits(%Parameter{datainfo: array_info(1200)}) < default
    end

    test "wide values get fewer readings and buckets than a plain number" do
      number = %Parameter{datainfo: %{"type" => "double"}}
      assert History.limits(number) == {3000, 400}

      # 100 values per reading: fewer readings in full
      assert {2000, 400} = History.limits(%Parameter{datainfo: array_info(100)})

      # 27 two-state fields: up to 56 readings per bucket, 27 values each
      valves =
        Map.new(
          1..27,
          &{"v#{&1}", %{"type" => "enum", "members" => %{"open" => 1, "closed" => 0}}}
        )

      assert {raw, buckets} =
               History.limits(%Parameter{datainfo: %{"type" => "struct", "members" => valves}})

      # ... while 3000 full readings still fit
      assert raw == 3000
      assert buckets == div(200_000, 27 * 56)
    end
  end

  describe "bucket_width/2" do
    test "picks the narrowest round width that needs no more buckets than allowed" do
      assert History.bucket_width(:timer.hours(1), 400) == :timer.seconds(10)
      assert History.bucket_width(:timer.hours(24), 400) == :timer.minutes(5)
      assert History.bucket_width(:timer.hours(24 * 10), 400) == :timer.hours(1)
      # beyond the list: whole days
      assert History.bucket_width(:timer.hours(24 * 2000), 400) == :timer.hours(24 * 5)
      assert History.bucket_width(0, 400) == 1
    end
  end

  describe "window/4" do
    test "a parameter without readings gives an empty window" do
      parameter = generate(parameter(datainfo: %{"type" => "double"}))

      assert History.window(parameter, nil, nil) ==
               %{values: [], timestamps: [], aggregated: false, bucket_ms: nil}
    end

    test "few readings come back as stored, oldest first" do
      parameter = generate(parameter(datainfo: %{"type" => "double"}))
      insert_readings(parameter, 50, &(&1 + 0.5))

      window = History.window(parameter, nil, nil, max_raw: 100)

      refute window.aggregated
      assert window.bucket_ms == nil
      assert points(window) == for(i <- 0..49, do: {ms(i), i + 0.5})
    end

    test "many readings are thinned out to real readings that keep the extremes" do
      parameter = generate(parameter(datainfo: %{"type" => "double"}))

      # flat at 20, with one spike up and one dip down
      value = fn
        1234 -> 99.5
        2345 -> -7.25
        _ -> 20.0
      end

      insert_readings(parameter, 3600, value)

      window = History.window(parameter, nil, nil, max_raw: 100, max_buckets: 60)

      assert window.aggregated
      assert window.bucket_ms == :timer.minutes(1)
      # at most 4 readings per bucket
      assert length(window.values) <= 4 * 60
      assert length(window.values) < 3600

      points = points(window)
      assert {ms(1234), 99.5} in points
      assert {ms(2345), -7.25} in points
      # the first and last reading stay, so the time axis keeps its extent
      assert hd(points) == {ms(0), 20.0}
      assert List.last(points) == {ms(3599), 20.0}
      assert window.timestamps == Enum.sort(window.timestamps)
      assert window.timestamps == Enum.uniq(window.timestamps)
    end

    test "a smaller window gets narrower buckets and finally every reading" do
      parameter = generate(parameter(datainfo: %{"type" => "int"}))
      insert_readings(parameter, 3600, & &1)
      opts = [max_raw: 100, max_buckets: 60]

      assert %{aggregated: true, bucket_ms: 60_000} = History.window(parameter, nil, nil, opts)

      assert %{aggregated: true, bucket_ms: 10_000} =
               History.window(parameter, ms(600), ms(1200), opts)

      zoomed = History.window(parameter, ms(600), ms(650), opts)

      refute zoomed.aggregated
      assert points(zoomed) == for(i <- 600..650, do: {ms(i), i})
    end

    test "open ends reach to the first and last reading" do
      parameter = generate(parameter(datainfo: %{"type" => "int"}))
      insert_readings(parameter, 20, & &1)

      assert History.window(parameter, ms(15), nil).values == Enum.to_list(15..19)
      assert History.window(parameter, nil, ms(3)).values == Enum.to_list(0..3)
    end

    test "only the asked parameter's readings are used" do
      parameter = generate(parameter(datainfo: %{"type" => "int"}))
      other = generate(parameter(datainfo: %{"type" => "int"}))
      insert_readings(parameter, 200, fn _ -> 1 end)
      insert_readings(other, 200, fn _ -> 1000 end)

      window = History.window(parameter, nil, nil, max_raw: 50, max_buckets: 10)

      assert window.aggregated
      assert Enum.uniq(window.values) == [1]
    end

    test "compressed chunks give the same answer" do
      parameter = generate(parameter(datainfo: %{"type" => "double"}))
      insert_readings(parameter, 600, &(rem(&1 * 7, 50) * 1.0))
      opts = [max_raw: 100, max_buckets: 20]

      thinned = History.window(parameter, nil, nil, opts)
      zoomed = History.window(parameter, ms(100), ms(150), opts)

      %{rows: [_ | _]} =
        Repo.query!("SELECT compress_chunk(c) FROM show_chunks('readings') c")

      assert History.window(parameter, nil, nil, opts) == thinned
      assert History.window(parameter, ms(100), ms(150), opts) == zoomed
    end
  end

  describe "resolution/4 and coarsest/1" do
    test "say how a window would be answered" do
      parameter = generate(parameter(datainfo: %{"type" => "int"}))
      insert_readings(parameter, 600, & &1)
      opts = [max_raw: 100, max_buckets: 60]

      assert History.resolution(parameter, nil, nil, opts) ==
               %{aggregated: true, bucket_ms: 10_000}

      assert History.resolution(parameter, ms(0), ms(50), opts) ==
               %{aggregated: false, bucket_ms: nil}
    end

    test "a plot of several parameters is as coarse as its coarsest one" do
      raw = %{aggregated: false, bucket_ms: nil}

      assert History.coarsest([raw, raw]) == raw
      assert History.coarsest([]) == raw

      assert History.coarsest([
               raw,
               %{aggregated: true, bucket_ms: 1000},
               %{aggregated: true, bucket_ms: 60_000}
             ]) == %{aggregated: true, bucket_ms: 60_000}
    end
  end

  describe "Parameter actions" do
    test ":history_window and :history_resolution answer like History" do
      parameter = generate(parameter(datainfo: %{"type" => "int"}))
      insert_readings(parameter, 600, & &1)
      limits = %{max_raw: 100, max_buckets: 60}

      thinned = SecNodes.history_window!(parameter.id, nil, nil, limits)
      assert thinned == History.window(parameter, nil, nil, Map.to_list(limits))
      assert thinned.aggregated

      assert SecNodes.history_resolution!(parameter.id, nil, nil, limits) ==
               %{aggregated: true, bucket_ms: 10_000}

      zoomed = SecNodes.history_window!(parameter.id, ms(10), ms(20))
      assert zoomed.values == Enum.to_list(10..20)
      refute zoomed.aggregated
    end

    test "accept arrays and structs" do
      parameter = generate(parameter(datainfo: array_info(2)))
      insert_readings(parameter, 20, &[&1 * 1.0, 0.0])

      assert %{values: [[+0.0, +0.0] | _], aggregated: false} =
               SecNodes.history_window!(parameter.id, nil, nil)
    end

    test "cap how many readings a caller may ask for, and when" do
      parameter = generate(parameter(datainfo: %{"type" => "double"}))

      assert {:error, %Ash.Error.Invalid{}} =
               SecNodes.history_window(parameter.id, 1_000_000_000_000_000_000, nil)

      assert {:error, %Ash.Error.Invalid{}} =
               SecNodes.history_resolution(parameter.id, -100_000_000_000_000_000, nil)

      # readings a node stamped before 1970 still load
      assert %{values: []} = SecNodes.history_window!(parameter.id, -1_000, nil)

      assert {:error, %Ash.Error.Invalid{}} =
               SecNodes.history_window(parameter.id, nil, nil, %{max_raw: 10_000_000})

      assert {:error, %Ash.Error.Invalid{}} =
               SecNodes.history_window(parameter.id, nil, nil, %{max_buckets: 10_000_000})
    end

    test ":history_window takes the envelope flag" do
      parameter = generate(parameter(datainfo: %{"type" => "double"}))
      insert_readings(parameter, 20, &(&1 * 1.0))

      # in the sandbox the aggregates are empty: the window is today's,
      # with the key saying no envelope was drawn
      with_envelope = SecNodes.history_window!(parameter.id, nil, nil, %{envelope: true})
      assert Map.fetch!(with_envelope, :envelope) == nil
      assert Map.delete(with_envelope, :envelope) == History.window(parameter, nil, nil)

      refute Map.has_key?(SecNodes.history_window!(parameter.id, nil, nil), :envelope)
    end

    test "refuse parameters that are not plotted, and unknown ones" do
      parameter = generate(parameter(datainfo: %{"type" => "string"}))

      assert {:error, %Ash.Error.Invalid{}} = SecNodes.history_window(parameter.id, nil, nil)
      assert {:error, %Ash.Error.Invalid{}} = SecNodes.history_resolution(parameter.id, nil, nil)
      assert {:error, %Ash.Error.Invalid{}} = SecNodes.history_window(-1, nil, nil)
    end
  end

  defp array_info(len, member \\ "double"),
    do: %{"type" => "array", "maxlen" => len, "members" => %{"type" => member}}

  describe "window/4 for other types" do
    test "an array keeps the extremes of every element, as whole readings" do
      parameter = generate(parameter(datainfo: array_info(3)))

      # element 1 spikes once, element 2 dips once, element 0 stays flat
      value = fn
        1234 -> [1.0, 99.5, 3.0]
        2345 -> [1.0, 2.0, -7.25]
        _ -> [1.0, 2.0, 3.0]
      end

      insert_readings(parameter, 3600, value)

      window = History.window(parameter, nil, nil, max_raw: 100, max_buckets: 60)

      assert window.aggregated
      assert window.bucket_ms == :timer.minutes(1)
      points = points(window)
      assert {ms(1234), [1.0, 99.5, 3.0]} in points
      assert {ms(2345), [1.0, 2.0, -7.25]} in points
      assert hd(points) == {ms(0), [1.0, 2.0, 3.0]}
      assert List.last(points) == {ms(3599), [1.0, 2.0, 3.0]}
      # per bucket: first, last and the extremes of 3 elements
      assert length(points) <= 60 * (2 + 2 * 3)
      assert window.timestamps == Enum.sort(window.timestamps)
    end

    test "a wide array is picked by the extremes of the whole array" do
      len = Channels.wide_array() + 4
      parameter = generate(parameter(datainfo: array_info(len, "int")))
      flat = List.duplicate(5, len)

      value = fn
        1234 -> List.replace_at(flat, len - 1, 500)
        2345 -> List.replace_at(flat, 0, -500)
        _ -> flat
      end

      insert_readings(parameter, 3600, value)

      window = History.window(parameter, nil, nil, max_raw: 100, max_buckets: 60)

      points = points(window)
      assert {ms(1234), List.replace_at(flat, len - 1, 500)} in points
      assert {ms(2345), List.replace_at(flat, 0, -500)} in points
      # first, last, lowest and highest per bucket, not per element
      assert length(points) <= 60 * 4
    end

    test "an enum keeps the first reading of every state in each bucket" do
      parameter =
        generate(
          parameter(datainfo: %{"type" => "enum", "members" => %{"a" => 0, "b" => 1, "c" => 2}})
        )

      # toggles 0/1 every second, and is 2 exactly once
      insert_readings(parameter, 3600, fn
        1234 -> 2
        i -> rem(i, 2)
      end)

      window = History.window(parameter, nil, nil, max_raw: 100, max_buckets: 60)

      assert window.aggregated
      assert {ms(1234), 2} in points(window)
      # every bucket shows both toggling states
      for bucket <- Enum.chunk_by(points(window), fn {ts, _} -> div(ts - ms(0), 60_000) end) do
        assert MapSet.subset?(MapSet.new([0, 1]), MapSet.new(bucket, &elem(&1, 1)))
      end

      # each bucket's last reading stays, so the band ends in the right state
      for bucket <- 0..59, do: assert({ms(bucket * 60 + 59), 1} in points(window))

      # per state its first and last run start, plus the last reading;
      # never one per change
      assert length(window.values) <= 60 * (1 + 2 * 3)
    end

    test "a short state in a bucket ends where it really ended" do
      parameter =
        generate(parameter(datainfo: %{"type" => "enum", "members" => %{"a" => 0, "b" => 1}}))

      # a for a minute, except b at 10 s .. 11 s of every minute
      insert_readings(parameter, 600, &if(rem(&1, 60) in [10, 11], do: 1, else: 0))

      window = History.window(parameter, nil, nil, max_raw: 100, max_buckets: 10)

      assert window.aggregated
      # b starts at 10 s and a takes over again at 12 s, not at the bucket end
      for bucket <- 0..9 do
        assert {ms(bucket * 60 + 10), 1} in points(window)
        assert {ms(bucket * 60 + 12), 0} in points(window)
      end
    end

    test "a struct keeps the extremes and states of each field, values as stored" do
      datainfo = %{
        "type" => "struct",
        "members" => %{
          "flow" => %{"type" => "double"},
          "mode" => %{"type" => "enum", "members" => %{"off" => 0, "on" => 1, "boost" => 2}},
          "temps" => array_info(2),
          "inner" => %{"type" => "struct", "members" => %{"p" => %{"type" => "int"}}},
          "label" => %{"type" => "string"}
        }
      }

      parameter = generate(parameter(datainfo: datainfo))

      base = %{
        "flow" => 1.0,
        "mode" => 0,
        "temps" => [20.0, 30.0],
        "inner" => %{"p" => 7},
        "label" => "x"
      }

      value = fn
        100 -> %{base | "flow" => 99.0}
        200 -> %{base | "mode" => 2}
        300 -> %{base | "temps" => [20.0, -40.0]}
        400 -> %{base | "inner" => %{"p" => 70}}
        # junk a node might send: must not break the query
        500 -> %{base | "flow" => "n/a", "temps" => "broken"}
        # a number beyond float8's range
        600 -> %{base | "flow" => Integer.pow(10, 400), "temps" => [Integer.pow(10, 400), 1.0]}
        _ -> base
      end

      insert_readings(parameter, 3600, value)

      window = History.window(parameter, nil, nil, max_raw: 100, max_buckets: 60)

      assert window.aggregated
      points = points(window)

      for i <- [100, 200, 300, 400] do
        assert {ms(i), value.(i)} in points, "reading #{i} missing"
      end

      assert length(points) < 3600
    end

    test "the picker of a type comes from the config" do
      parameter = generate(parameter(datainfo: %{"type" => "double"}))

      value = fn
        1234 -> 99.5
        _ -> 20.0
      end

      insert_readings(parameter, 3600, value)
      opts = [max_raw: 100, max_buckets: 60]

      Application.put_env(:secant_service, History, pickers: %{"double" => :first_last})
      on_exit(fn -> Application.delete_env(:secant_service, History) end)

      first_last = History.window(parameter, nil, nil, opts)
      refute {ms(1234), 99.5} in points(first_last)
      assert length(first_last.values) <= 2 * 60

      Application.put_env(:secant_service, History, pickers: %{"double" => :bogus})
      assert_raise ArgumentError, fn -> History.window(parameter, nil, nil, opts) end
    end

    test "compressed chunks give the same answer for enums, arrays and structs" do
      array = generate(parameter(datainfo: array_info(2)))
      insert_readings(array, 600, &[rem(&1 * 7, 50) * 1.0, rem(&1 * 3, 11) * 1.0])

      struct =
        generate(
          parameter(datainfo: %{"type" => "struct", "members" => %{"f" => %{"type" => "double"}}})
        )

      insert_readings(struct, 600, &%{"f" => rem(&1 * 7, 50) * 1.0})

      enum =
        generate(parameter(datainfo: %{"type" => "enum", "members" => %{"a" => 0, "b" => 1}}))

      insert_readings(enum, 600, &rem(div(&1, 7), 2))
      opts = [max_raw: 100, max_buckets: 20]
      params = [enum, array, struct]

      before = for p <- params, do: History.window(p, nil, nil, opts)
      assert Enum.all?(before, & &1.aggregated)

      %{rows: [_ | _]} =
        Repo.query!("SELECT compress_chunk(c) FROM show_chunks('readings') c")

      assert before == for(p <- params, do: History.window(p, nil, nil, opts))
    end
  end

  defp count_messages(message, count \\ 0) do
    receive do
      ^message -> count_messages(message, count + 1)
    after
      0 -> count
    end
  end

  # the session of `parameter` started at `at`
  defp start_session_at(parameter, at) do
    %{module: %{sec_node: node}} = SecNodes.get_parameter!(parameter.id)
    {:ok, uuid} = Ecto.UUID.dump(node.uuid)

    {1, _} =
      Repo.update_all(from(n in "sec_nodes", where: n.uuid == ^uuid),
        set: [inserted_at: DateTime.to_naive(at)]
      )

    :ok
  end

  describe "historical plot data" do
    test "numeric parameters are loaded thinned out" do
      parameter = generate(parameter(datainfo: %{"type" => "double"}))
      start_session_at(parameter, @start)
      insert_readings(parameter, 4000, &(rem(&1, 10) * 1.0))

      {values, timestamps} = fetch_historical(parameter)

      assert length(values) == length(timestamps)
      assert length(values) < 4000
      assert hd(timestamps) == ms(0)
      assert List.last(timestamps) == ms(3999)
    end

    # Unchanged parameters carry the node's time of their last change, often
    # long before the recording began; they must not stretch the time axis.
    test "arrays, enums and structs are loaded thinned out, and their plots fetch detail" do
      enum = %{"type" => "enum", "members" => %{"off" => 0, "on" => 1}}

      cases = [
        {array_info(2), &[rem(&1, 10) * 1.0, 1.0]},
        {enum, &rem(&1, 2)},
        {%{"type" => "struct", "members" => %{"f" => %{"type" => "double"}, "m" => enum}},
         &%{"f" => rem(&1, 10) * 1.0, "m" => rem(&1, 2)}}
      ]

      for {datainfo, value_fun} <- cases do
        parameter = generate(parameter(datainfo: datainfo))
        start_session_at(parameter, @start)
        insert_readings(parameter, 4000, value_fun)

        {values, timestamps} = fetch_historical(parameter)
        assert length(values) < 4000, datainfo["type"]
        assert hd(timestamps) == ms(0)
        assert List.last(timestamps) == ms(3999)

        assert [%{param: %{id: id}}] = PlotDB.lines(parameter)
        assert id == parameter.id

        plot = PlotDB.init(parameter, :historical)
        assert %{aggregated: true} = plot.option._windowFetch, datainfo["type"]
      end
    end

    # The plot takes its resolution from the readings it loaded, instead of
    # asking the database again for each parameter.
    test "a drivable plot reports its resolution without a second pass" do
      module = generate(sec_module(interface_classes: ["Drivable"]))
      value = generate(parameter(module_id: module.id, name: "value"))
      target = generate(parameter(module_id: module.id, name: "target"))
      start_session_at(value, @start)
      insert_readings(value, 4000, &(rem(&1, 10) * 1.0))
      insert_readings(target, 3, &(&1 * 1.0))
      module = Ash.load!(module, :parameters)

      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "#{inspect(ref)}",
        [:secant_service, :repo, :query],
        fn _event, _measurements, _meta, _ -> send(test_pid, {ref, :query}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("#{inspect(ref)}") end)

      plot = PlotDB.init(module, :historical)
      :telemetry.detach("#{inspect(ref)}")

      assert plot.option._windowFetch ==
               History.coarsest([
                 SecNodes.history_resolution!(value.id, ms(0), nil),
                 SecNodes.history_resolution!(target.id, ms(0), nil)
               ])

      assert %{aggregated: true} = plot.option._windowFetch

      # per parameter: its session start, its second reading, the window
      # (parameter, bounds, count, readings) and the held reading before it;
      # loading the resolution again doubled this
      assert count_messages({ref, :query}) <= 14
    end

    test "a zoomed enum window comes back as state points" do
      datainfo = %{"type" => "enum", "members" => %{"off" => 0, "on" => 1}}
      parameter = generate(parameter(datainfo: datainfo))
      start_session_at(parameter, @start)
      insert_readings(parameter, 20, &rem(&1, 2))

      plot = PlotDB.init(parameter, :historical)
      window = History.window(parameter, ms(5), ms(6))

      assert %{seriesUpdates: [%{data: [%{value: [_, 0], name: "on (1)"}, %{name: "off (0)"}]}]} =
               PlotDB.trace_updates(
                 plot,
                 Enum.zip(window.values, window.timestamps),
                 "value"
               )
    end

    test "readings from before the session are pinned to its start" do
      for {type, value_fun} <- [{"double", &(&1 * 1.0)}, {"bool", &(rem(&1, 2) == 1)}] do
        parameter = generate(parameter(datainfo: %{"type" => type}))
        insert_readings(parameter, 20, value_fun)
        # a stale first reading (index 0), the session from index 10 on
        {9, _} =
          Repo.delete_all(
            from r in "readings",
              where:
                r.parameter_id == ^parameter.id and
                  r.timestamp > ^DateTime.to_naive(@start) and
                  r.timestamp < ^DateTime.to_naive(DateTime.add(@start, 10, :second))
          )

        start_session_at(parameter, DateTime.add(@start, 10, :second))

        {values, timestamps} = fetch_historical(parameter)

        # the stale reading pinned to the start, then 10..19
        assert timestamps == [ms(10) | Enum.map(10..19, &ms/1)]
        assert values == Enum.map([0 | Enum.to_list(10..19)], value_fun)
        assert Builders.plot_start_ms(parameter) == ms(10)
      end
    end

    test "a parameter only set before the session plots from the start" do
      parameter = generate(parameter(datainfo: %{"type" => "double"}))
      # stored twice (at-least-once delivery): still one stale reading
      insert_readings(parameter, 1, fn _ -> 2.5 end)
      insert_readings(parameter, 1, fn _ -> 2.5 end)
      start_session_at(parameter, DateTime.add(@start, 3600, :second))

      assert fetch_historical(parameter) == {[2.5], [ms(3600)]}
    end

    test "a node clock behind the server's hides no readings" do
      parameter = generate(parameter(datainfo: %{"type" => "double"}))
      insert_readings(parameter, 20, &(&1 * 1.0))
      # every reading is stamped before the session start
      start_session_at(parameter, DateTime.add(@start, 60, :second))

      assert Builders.plot_start_ms(parameter) == ms(1)
      {values, timestamps} = fetch_historical(parameter)

      # only the first reading is pinned, to the second one
      assert timestamps == [ms(1) | Enum.map(1..19, &ms/1)]
      assert values == [0.0 | Enum.map(1..19, &(&1 * 1.0))]
    end
  end

  describe "Envelope arithmetic" do
    alias SecantService.PlotDB.History.Envelope

    @min 60_000
    @hour 3_600_000
    @day 86_400_000
    # 2000-01-03 00:00 UTC, time_bucket's default origin
    @origin 946_857_600_000

    test "edges: aligned windows keep their edges, unaligned ones move inwards" do
      t = @origin + 10 * @hour
      assert Envelope.edges(t, t + 2 * @hour, @hour) == {t, t + 2 * @hour}
      assert Envelope.edges(t + 1, t + 2 * @hour - 1, @hour) == {t + @hour, t + @hour}
      assert Envelope.edges(t + 30 * @min, t + 3 * @hour + 5, @hour) == {t + @hour, t + 3 * @hour}
    end

    test "edges: a window holding no whole bucket has a >= b" do
      t = @origin + 10 * @hour + 1
      {a, b} = Envelope.edges(t, t + 30 * @min, @hour)
      assert a >= b
    end

    test "edges: multi-day widths and instants before 2000 use the same origin" do
      # 2-day buckets start on the origin's grid, not at the Unix epoch
      two_days = 2 * @day
      from = @origin + 3 * @day + 5

      assert Envelope.edges(from, from + 10 * @day, two_days) ==
               {@origin + 4 * @day, @origin + 12 * @day}

      # 1999-12-31 12:00 UTC
      before_2000 = @origin - 2 * @day - 12 * @hour
      assert Envelope.floor_to(before_2000, @day) == @origin - 3 * @day

      assert Envelope.edges(before_2000, before_2000 + @day, @day) ==
               {@origin - 2 * @day, @origin - 2 * @day}

      # and before 1970
      assert Envelope.floor_to(-1, @min) == -@min
    end

    test "until: the materialized point, floored and kept within [a, b]" do
      a = @origin + 10 * @hour
      b = a + 5 * @hour

      # never refreshed
      assert Envelope.until(a, b, nil, @hour) == a
      # watermark before the window
      assert Envelope.until(a, b, a - 3 * @hour, @hour) == a
      # inside: floored to a bucket boundary
      assert Envelope.until(a, b, a + 2 * @hour + 17, @hour) == a + 2 * @hour
      # after the window
      assert Envelope.until(a, b, b + @day, @hour) == b
    end

    test "point_time: the bucket centre, moved into the span of its readings" do
      bucket = @origin + 10 * @hour
      w = 15 * @min

      assert Envelope.point_time(bucket, w, bucket, bucket + w - 1) == bucket + div(w, 2)
      # the only reading lies after the centre
      only = bucket + 10 * @min
      assert Envelope.point_time(bucket, w, only, only) == only
      # all readings before the centre
      assert Envelope.point_time(bucket, w, bucket, bucket + @min) == bucket + @min
    end
  end
end
