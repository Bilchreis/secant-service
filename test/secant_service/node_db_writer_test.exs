defmodule SecantService.NodeDBWriterTest do
  @moduledoc """
  The writer keeps a faithful record: every value with a new timestamp is
  stored, only exact repeats (same timestamp and value) are skipped, also
  across a restart of the writer.
  """
  use SecantService.NodeCase, async: false

  alias SecantService.{NodeDBWriter, SecNodes}
  alias SecantService.SecNodes.Reading.Storage

  @desc %{"temp" => ["value", "status"]}

  setup do
    Phoenix.PubSub.subscribe(SecantService.PubSub, SecantService.Topics.node_services())
    node_id = unique_node_id()
    state = connect_node(node_id, raw_description("eq-#{elem(node_id, 1)}", @desc))
    assert_receive {:node_services_ready, ^node_id, _}, 5_000

    {:ok, parameters} = SecNodes.parameters_of_node(state.uuid)
    temp = Enum.find(parameters, &(&1.module.name == "temp" and &1.name == "value"))
    {:ok, node_id: node_id, uuid: state.uuid, temp: temp}
  end

  defp writer(uuid) do
    [{pid, _}] = Registry.lookup(Registry.NodeDBWriter, uuid)
    pid
  end

  # flush now and wait for the (async) insert
  defp flush_and_read(uuid, temp, expected_count) do
    send(writer(uuid), :flush_parameter_batch)

    eventually(fn -> length(SecNodes.readings!(temp)) == expected_count end)

    temp
    |> SecNodes.readings!()
    |> Enum.map(&{DateTime.to_unix(&1.timestamp), Storage.raw_value(&1)})
    # readings with the same timestamp have no defined order
    |> Enum.sort()
  end

  test "stores fresh timestamps and different values, skips exact repeats",
       %{node_id: node_id, uuid: uuid, temp: temp} do
    # the initial value (1.0 at t=1_700_000_000) was written at start
    send_value_update(node_id, "temp", "value", [5.0, %{t: 1_700_000_100.0}])
    send_value_update(node_id, "temp", "value", [5.0, %{t: 1_700_000_100.0}])
    send_value_update(node_id, "temp", "value", [5.0, %{t: 1_700_000_101.0}])
    send_value_update(node_id, "temp", "value", [6.0, %{t: 1_700_000_101.0}])

    assert flush_and_read(uuid, temp, 4) == [
             {1_700_000_000, 1.0},
             {1_700_000_100, 5.0},
             {1_700_000_101, 5.0},
             {1_700_000_101, 6.0}
           ]
  end

  test "a writer restart does not store a steady value's older reading again",
       %{node_id: node_id, uuid: uuid, temp: temp} do
    # NodeValues ignores unchanged values, so it keeps 5.0@100 while the
    # node goes on reporting 5.0 with new timestamps
    for t <- [100, 101, 102] do
      send_value_update(node_id, "temp", "value", [5.0, %{t: 1_700_000_000.0 + t}])
    end

    assert length(flush_and_read(uuid, temp, 4)) == 4

    old = writer(uuid)
    Process.exit(old, :kill)

    eventually(fn ->
      match?([{pid, _}] when pid != old, Registry.lookup(Registry.NodeDBWriter, uuid))
    end)

    # the resend of the last reading on reactivation is a repeat, too
    send_value_update(node_id, "temp", "value", [5.0, %{t: 1_700_000_102.0}])
    send_value_update(node_id, "temp", "value", [5.0, %{t: 1_700_000_103.0}])

    assert flush_and_read(uuid, temp, 5) == [
             {1_700_000_000, 1.0},
             {1_700_000_100, 5.0},
             {1_700_000_101, 5.0},
             {1_700_000_102, 5.0},
             {1_700_000_103, 5.0}
           ]
  end

  test "a resend after the writer restarted is recognised as a repeat",
       %{node_id: node_id, uuid: uuid, temp: temp} do
    send_value_update(node_id, "temp", "value", [7.0, %{t: 1_700_000_200.0}])
    assert length(flush_and_read(uuid, temp, 2)) == 2

    old = writer(uuid)
    Process.exit(old, :kill)

    eventually(fn ->
      match?([{pid, _}] when pid != old, Registry.lookup(Registry.NodeDBWriter, uuid))
    end)

    # what a node resends when it is activated again
    send_value_update(node_id, "temp", "value", [7.0, %{t: 1_700_000_200.0}])
    send_value_update(node_id, "temp", "value", [7.0, %{t: 1_700_000_201.0}])

    assert flush_and_read(uuid, temp, 3) == [
             {1_700_000_000, 1.0},
             {1_700_000_200, 7.0},
             {1_700_000_201, 7.0}
           ]
  end

  describe "writing" do
    setup %{temp: temp} do
      # the initial value is stored before each test starts
      eventually(fn -> length(SecNodes.readings!(temp)) == 1 end)

      on_exit(fn ->
        for key <- [:insert_readings, :writer_retry_delay, :writer_max_buffered_weight] do
          Application.delete_env(:secant_service, key)
        end
      end)

      Application.put_env(:secant_service, :writer_retry_delay, 10)
      :ok
    end

    # An insert that can't reach the database while `down?` returns true,
    # recording the time of each attempt.
    defp outage(down?) do
      test_pid = self()

      Application.put_env(:secant_service, :insert_readings, fn rows ->
        send(test_pid, {:attempt, System.monotonic_time(:millisecond), length(rows)})

        if down?.(),
          do: raise(DBConnection.ConnectionError, "connection not available"),
          else: SecNodes.insert_readings(rows)
      end)
    end

    defp stored(temp) do
      temp
      |> SecNodes.readings!()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&{DateTime.to_unix(&1.timestamp), Storage.raw_value(&1)})
    end

    # logs the failed writes
    @tag :capture_log
    test "readings the database could not take are retried, in the order they came",
         %{node_id: node_id, uuid: uuid, temp: temp} do
      down = :counters.new(1, [])
      :counters.put(down, 1, 1)
      outage(fn -> :counters.get(down, 1) == 1 end)

      send_value_update(node_id, "temp", "value", [5.0, %{t: 1_700_000_100.0}])
      send(writer(uuid), :flush_parameter_batch)
      assert_receive {:attempt, _, 1}

      # arrives while the first write is being retried
      send_value_update(node_id, "temp", "value", [6.0, %{t: 1_700_000_101.0}])
      assert_receive {:attempt, _, 2}
      :counters.put(down, 1, 0)

      eventually(fn -> length(SecNodes.readings!(temp)) == 3 end)

      assert stored(temp) == [
               {1_700_000_000, 1.0},
               {1_700_000_100, 5.0},
               {1_700_000_101, 6.0}
             ]
    end

    # logs the failed writes
    @tag :capture_log
    test "retries back off", %{node_id: node_id, uuid: uuid} do
      outage(fn -> true end)

      send_value_update(node_id, "temp", "value", [5.0, %{t: 1_700_000_100.0}])
      send(writer(uuid), :flush_parameter_batch)

      times =
        for _ <- 1..5 do
          assert_receive {:attempt, t, _}, 2_000
          t
        end

      gaps = times |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)

      # 10, 20, 40, 80 ms
      assert gaps == Enum.sort(gaps)
      assert List.last(gaps) >= 70
    end

    # logs the failed writes and the overflow
    @tag :capture_log
    test "a full buffer drops the oldest readings; a resend of one is stored",
         %{node_id: node_id, temp: temp} do
      # room for 6 scalar readings (21 each); trimmed to 117
      Application.put_env(:secant_service, :writer_max_buffered_weight, 130)
      NodeSupervisor.stop_node_services(node_id)
      NodeManager.sync_nodes!()
      assert_receive {:node_services_ready, ^node_id, uuid}, 5_000
      eventually(fn -> match?(%{in_flight: nil, queued: 0}, :sys.get_state(writer(uuid))) end)

      {:ok, parameters} = SecNodes.parameters_of_node(uuid)
      status = Enum.find(parameters, &(&1.module.name == "temp" and &1.name == "status"))
      statuses_before = length(SecNodes.readings!(status))
      status_report = [[100, "ok"], %{t: 1_700_000_050.0}]

      down = :counters.new(1, [])
      :counters.put(down, 1, 1)
      outage(fn -> :counters.get(down, 1) == 1 end)

      # the newest status reading is the oldest in the buffer...
      send_value_update(node_id, "temp", "status", status_report)

      for t <- 1..6 do
        send_value_update(node_id, "temp", "value", [t * 1.0, %{t: 1_700_000_100.0 + t}])
      end

      # ...and is dropped (with temp 1) when the 6th temp fills the buffer.
      # The node resends it, e.g. after a reconnect: it was never stored, so
      # it is no repeat.
      :counters.put(down, 1, 0)
      send_value_update(node_id, "temp", "status", status_report)
      send(writer(uuid), :flush_parameter_batch)

      eventually(fn -> {1_700_000_106, 6.0} in stored(temp) end)
      assert length(SecNodes.readings!(status)) == statuses_before + 1

      new = for {t, v} <- stored(temp), t > 1_700_000_100, do: v
      assert new == [2.0, 3.0, 4.0, 5.0, 6.0]
    end

    test "on stop the whole buffer is written, in statements of at most 1000",
         %{node_id: node_id, temp: temp} do
      outage(fn -> false end)

      for t <- 1..2_500 do
        send_value_update(node_id, "temp", "value", [t * 1.0, %{t: 1_700_000_000.0 + t}])
      end

      NodeSupervisor.stop_node_services(node_id)

      assert length(SecNodes.readings!(temp)) == 2_501
      sizes = for {:attempt, _, n} <- flush_messages(), do: n
      assert Enum.sum(sizes) == 2_500
      assert Enum.max(sizes) <= 1_000
    end

    # logs the dropped readings
    @tag :capture_log
    test "only the readings the database rejects are dropped", %{temp: temp} do
      gone = %{temp | id: -1}

      rows =
        for {parameter, t} <- [{temp, 1}, {gone, 2}, {temp, 3}, {temp, 4}, {gone, 5}] do
          Storage.to_row(t * 1.0, parameter, 1_700_000_000.0 + t, %{})
        end

      assert {:ok, rejected} = NodeDBWriter.insert(rows)
      # the database says why: the parameter is gone
      assert [%{deleted: -1}, %{deleted: -1}] = rejected

      assert temp |> SecNodes.readings!() |> Enum.map(&Storage.raw_value/1) |> Enum.sort() ==
               [1.0, 1.0, 3.0, 4.0]
    end

    # logs the dropped reading
    @tag :capture_log
    test "an outage while splitting a batch keeps the rest for the retry", %{temp: temp} do
      gone = %{temp | id: -1}

      [ok1, bad, ok3, ok4] =
        for {parameter, t} <- [{temp, 1}, {gone, 2}, {temp, 3}, {temp, 4}] do
          Storage.to_row(t * 1.0, parameter, 1_700_000_000.0 + t, %{})
        end

      # the database goes away once the first half is done
      Application.put_env(:secant_service, :insert_readings, fn rows ->
        if ok3 in rows and length(rows) < 4,
          do: raise(DBConnection.ConnectionError, "connection not available"),
          else: SecNodes.insert_readings(rows)
      end)

      assert {:retry, [^ok3, ^ok4], [_rejected]} = NodeDBWriter.insert([ok1, bad, ok3, ok4])
    end

    # logs the dropped reading
    @tag :capture_log
    test "a reading the code can't write is dropped, not retried forever", %{temp: temp} do
      [ok, broken] =
        for v <- [2.0, 3.0], do: Storage.to_row(v, temp, 1_700_000_000.0 + v, %{})

      Application.put_env(:secant_service, :insert_readings, fn rows ->
        if broken in rows, do: raise("a bug"), else: SecNodes.insert_readings(rows)
      end)

      assert {:ok, [rejected]} = NodeDBWriter.insert([ok, broken])
      # a bad reading does not stop the recording of its parameter
      refute Map.has_key?(rejected, :deleted)
      assert 2.0 in Enum.map(SecNodes.readings!(temp), &Storage.raw_value/1)
    end
  end

  describe "parameters deleted and writes that crash" do
    setup %{temp: temp} do
      eventually(fn -> length(SecNodes.readings!(temp)) == 1 end)

      on_exit(fn ->
        for key <- [:insert_readings, :writer_retry_delay] do
          Application.delete_env(:secant_service, key)
        end
      end)

      Application.put_env(:secant_service, :writer_retry_delay, 10)
      :ok
    end

    defp idle(uuid) do
      eventually(fn ->
        state = :sys.get_state(writer(uuid))
        state.in_flight == nil and state.queued == 0
      end)
    end

    # logs the dropped reading and the deleted parameter
    @tag :capture_log
    test "a parameter deleted while recording is no longer written",
         %{node_id: node_id, uuid: uuid, temp: temp} do
      idle(uuid)
      {:ok, parameters} = SecNodes.parameters_of_node(uuid)
      status = Enum.find(parameters, &(&1.module.name == "temp" and &1.name == "status"))
      Ash.destroy!(status)

      test_pid = self()

      Application.put_env(:secant_service, :insert_readings, fn rows ->
        send(test_pid, {:attempt, rows |> Enum.map(& &1.parameter_id) |> Enum.uniq()})
        SecNodes.insert_readings(rows)
      end)

      write = fn t ->
        send_value_update(node_id, "temp", "status", [[100, "ok #{t}"], %{t: 1_700_000_000.0 + t}])

        send_value_update(node_id, "temp", "value", [t * 1.0, %{t: 1_700_000_000.0 + t}])
        send(writer(uuid), :flush_parameter_batch)
        idle(uuid)
      end

      write.(1)
      assert [1.0] = temp |> stored() |> tl() |> Enum.map(&elem(&1, 1))
      flush_messages()

      # the status reading is no longer sent
      write.(2)
      assert_received {:attempt, [id]}
      assert id == temp.id
      refute_received {:attempt, _}
      assert [1.0, 2.0] = temp |> stored() |> tl() |> Enum.map(&elem(&1, 1))
    end

    # logs the dropped readings and the deleted parameter
    @tag :capture_log
    test "the buffered readings of a deleted parameter are dropped, and counted",
         %{node_id: node_id, uuid: uuid, temp: temp} do
      idle(uuid)
      {:ok, parameters} = SecNodes.parameters_of_node(uuid)
      status = Enum.find(parameters, &(&1.module.name == "temp" and &1.name == "status"))
      Ash.destroy!(status)

      test_pid = self()
      handler = "dropped-#{inspect(test_pid)}"

      :telemetry.attach(
        handler,
        [:secant_service, :node_db_writer, :dropped],
        fn _, m, _, _ ->
          send(test_pid, {:dropped, m.count})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      first? = :counters.new(1, [])

      # the first write waits for the test, so more readings pile up behind it
      Application.put_env(:secant_service, :insert_readings, fn rows ->
        if :counters.get(first?, 1) == 0 do
          :counters.add(first?, 1, 1)
          send(test_pid, {:blocked, self()})
          receive do: (:go -> :ok)
        end

        send(test_pid, {:attempt, rows |> Enum.map(& &1.parameter_id) |> Enum.uniq()})
        SecNodes.insert_readings(rows)
      end)

      send_reading = fn t ->
        send_value_update(node_id, "temp", "status", [[100, "ok #{t}"], %{t: 1_700_000_000.0 + t}])

        send_value_update(node_id, "temp", "value", [t * 1.0, %{t: 1_700_000_000.0 + t}])
      end

      send_reading.(1)
      send(writer(uuid), :flush_parameter_batch)
      assert_receive {:blocked, task}

      send_reading.(2)
      send_reading.(3)
      assert :sys.get_state(writer(uuid)).queued == 4
      send(task, :go)

      # the first write finds the status parameter gone, the buffer loses its readings
      assert_receive {:dropped, 1}
      assert_receive {:dropped, 2}
      state = :sys.get_state(writer(uuid))
      assert state.queued == 2
      assert Enum.all?(:queue.to_list(state.queue), &(&1.parameter_id == temp.id))

      flush_messages()
      send(writer(uuid), :flush_parameter_batch)
      idle(uuid)
      assert :sys.get_state(writer(uuid)).weight == 0
      assert_received {:attempt, [id]}
      assert id == temp.id
      refute_received {:attempt, _}
      assert [1.0, 2.0, 3.0] = temp |> stored() |> tl() |> Enum.map(&elem(&1, 1))
    end

    # logs the crash
    @tag :capture_log
    test "a write that crashes while splitting a batch resends only what it had not stored",
         %{node_id: node_id, uuid: uuid, temp: temp} do
      crashed = :counters.new(1, [])
      bad? = &(DateTime.to_unix(&1.timestamp) == 1_700_000_002)

      # [1, 2, 3, 4] fails, so does [1, 2]; [1] is stored, then the write
      # crashes on [2]. The retry must not store 1 again.
      Application.put_env(:secant_service, :insert_readings, fn rows ->
        cond do
          :counters.get(crashed, 1) > 0 ->
            SecNodes.insert_readings(rows)

          match?([_], rows) and Enum.all?(rows, bad?) ->
            :counters.add(crashed, 1, 1)
            Process.exit(self(), :kill)

          Enum.any?(rows, bad?) ->
            raise "a bug"

          true ->
            SecNodes.insert_readings(rows)
        end
      end)

      for t <- 1..4 do
        send_value_update(node_id, "temp", "value", [t * 1.0, %{t: 1_700_000_000.0 + t}])
      end

      send(writer(uuid), :flush_parameter_batch)
      eventually(fn -> :counters.get(crashed, 1) == 1 end)
      idle(uuid)

      assert [1.0, 2.0, 3.0, 4.0] = temp |> stored() |> tl() |> Enum.map(&elem(&1, 1))
    end
  end

  defp flush_messages do
    receive do
      message -> [message | flush_messages()]
    after
      0 -> []
    end
  end
end
