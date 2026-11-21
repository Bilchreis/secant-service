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
    Phoenix.PubSub.subscribe(SecantService.PubSub, NodeManager.services_topic())
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
    # logs the failed writes
    @tag :capture_log
    test "a batch the database could not take is retried until it is stored",
         %{node_id: node_id, uuid: uuid, temp: temp} do
      eventually(fn -> length(SecNodes.readings!(temp)) == 1 end)
      failures = :counters.new(1, [])

      failing = fn rows ->
        if :counters.get(failures, 1) < 2 do
          :counters.add(failures, 1, 1)
          raise DBConnection.ConnectionError, "connection not available"
        else
          SecNodes.insert_readings(rows)
        end
      end

      Application.put_env(:secant_service, :insert_readings, failing)
      Application.put_env(:secant_service, :writer_retry_delay, 10)

      on_exit(fn ->
        Application.delete_env(:secant_service, :insert_readings)
        Application.delete_env(:secant_service, :writer_retry_delay)
      end)

      send_value_update(node_id, "temp", "value", [5.0, %{t: 1_700_000_100.0}])
      send_value_update(node_id, "temp", "value", [6.0, %{t: 1_700_000_101.0}])

      assert flush_and_read(uuid, temp, 3) == [
               {1_700_000_000, 1.0},
               {1_700_000_100, 5.0},
               {1_700_000_101, 6.0}
             ]

      assert :counters.get(failures, 1) == 2
    end

    # logs the dropped reading
    @tag :capture_log
    test "only the readings the database rejects are dropped", %{temp: temp} do
      eventually(fn -> length(SecNodes.readings!(temp)) == 1 end)
      gone = %{temp | id: -1}

      rows =
        for {parameter, t} <- [{temp, 1}, {gone, 2}, {temp, 3}, {temp, 4}, {gone, 5}] do
          Storage.to_row(t * 1.0, parameter, 1_700_000_000.0 + t, %{})
        end

      assert NodeDBWriter.insert(rows) == {:ok, 2}

      assert temp |> SecNodes.readings!() |> Enum.map(&Storage.raw_value/1) |> Enum.sort() ==
               [1.0, 1.0, 3.0, 4.0]
    end
  end
end
