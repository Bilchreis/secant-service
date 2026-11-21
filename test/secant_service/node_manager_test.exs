defmodule SecantService.NodeManagerTest do
  @moduledoc """
  Node lifecycle as seen by the service: whatever secant_client reports about
  a node, the running node services must serve the description of the node's
  current uuid, and the DB must hold exactly one active record for it.
  """
  use SecantService.NodeCase, async: false

  require Ash.Query

  @desc_a %{"temp" => ["value", "status", "target"], "press" => ["value", "status"]}
  # "press" removed, "flow" added, "temp" gained a parameter
  @desc_b %{"temp" => ["value", "status", "target", "ramp"], "flow" => ["value", "status"]}

  setup do
    Phoenix.PubSub.subscribe(SecantService.PubSub, NodeManager.services_topic())
    {:ok, node_id: unique_node_id()}
  end

  defp connect(node_id, modules) do
    state = connect_node(node_id, raw_description("eq-#{elem(node_id, 1)}", modules))
    assert_receive {:node_services_ready, ^node_id, uuid}, 5_000
    assert uuid == state.uuid
    state
  end

  defp record_state(uuid), do: Ash.get!(SecNode, uuid).state

  defp active_records(node_id) do
    {host, port} = node_id

    SecNode
    |> Ash.Query.filter(host == ^to_string(host) and port == ^port and state == :active)
    |> Ash.read!()
  end

  describe "new node" do
    test "is stored and gets services serving its description", %{node_id: node_id} do
      state = connect(node_id, @desc_a)

      assert NodeSupervisor.running_uuid(node_id) == state.uuid
      assert served_modules(node_id) == sorted(@desc_a)
      assert [%{uuid: uuid}] = active_records(node_id)
      assert uuid == state.uuid
    end

    test "starts a plot cache for every parameter", %{node_id: node_id} do
      connect(node_id, @desc_a)

      expected =
        for {module, params} <- @desc_a, param <- params, into: MapSet.new(), do: {module, param}

      assert PlotCache.parameters(node_id) == expected
    end

    test "batches live values for the plots", %{node_id: node_id} do
      connect(node_id, @desc_a)
      Phoenix.PubSub.subscribe(SecantService.PubSub, "plot_data:#{topic(node_id)}")

      send_value_update(node_id, "temp", "value", [1.0, %{t: 1_700_000_001.0}])
      send_value_update(node_id, "temp", "value", [2.0, %{t: 1_700_000_002.0}])
      send_value_update(node_id, "press", "value", [3.0, %{t: 1_700_000_003.0}])
      # not in the description: dropped
      send_value_update(node_id, "nope", "value", [4.0, %{t: 1_700_000_004.0}])
      :ok = PlotCache.flush(node_id)

      assert_receive {:plot_data, batch}

      assert Enum.sort(batch) == [
               {"press", "value", [[3.0, %{t: 1_700_000_003.0}]]},
               {"temp", "value", [[1.0, %{t: 1_700_000_001.0}], [2.0, %{t: 1_700_000_002.0}]]}
             ]
    end

    test "that is still handshaking (no description) is skipped", %{node_id: node_id} do
      state = node_state(node_id, raw_description("eq", @desc_a))
      start_supervised!({FakeNodeStatem, {node_id, %{state | description: nil}, []}})

      assert :ok = NodeManager.sync_nodes!()
      refute NodeSupervisor.services_running?(node_id)
      refute_received {:node_services_ready, ^node_id, _}
    end
  end

  describe "reconnect with a changed description" do
    # Regression: the description change used to be ignored for nodes that
    # were first seen through :new_node, leaving the services (and the UI) on
    # the old description until the app was restarted.
    test "restarts the services from the new description", %{node_id: node_id} do
      old = connect(node_id, @desc_a)
      old_pid = NodeSupervisor.get_services_pid(node_id)

      new = change_description(node_id, raw_description("eq-b", @desc_b))
      flush_node_manager()

      assert_receive {:node_services_ready, ^node_id, new_uuid}, 5_000
      assert new_uuid == new.uuid
      assert new.uuid != old.uuid
      assert NodeSupervisor.running_uuid(node_id) == new.uuid
      assert NodeSupervisor.get_services_pid(node_id) != old_pid
      assert served_modules(node_id) == sorted(@desc_b)
    end

    test "archives the replaced record, keeping one active record", %{node_id: node_id} do
      old = connect(node_id, @desc_a)
      new = change_description(node_id, raw_description("eq-b", @desc_b))
      assert_receive {:node_services_ready, ^node_id, _}, 5_000

      assert record_state(old.uuid) != :active
      assert [%{uuid: uuid}] = active_records(node_id)
      assert uuid == new.uuid
    end

    test "plot caches follow the new parameters", %{node_id: node_id} do
      connect(node_id, @desc_a)
      change_description(node_id, raw_description("eq-b", @desc_b))
      assert_receive {:node_services_ready, ^node_id, _}, 5_000

      parameters = PlotCache.parameters(node_id)
      assert {"flow", "value"} in parameters
      assert {"temp", "ramp"} in parameters
      refute {"press", "value"} in parameters
    end

    test "values of newly added parameters reach the services", %{node_id: node_id} do
      connect(node_id, @desc_a)
      change_description(node_id, raw_description("eq-b", @desc_b))
      assert_receive {:node_services_ready, ^node_id, _}, 5_000

      Phoenix.PubSub.subscribe(SecantService.PubSub, "value_update:processed:#{topic(node_id)}")
      send_value_update(node_id, "flow", "value", [12.5, %{t: 1_700_000_100.0}])

      assert_receive {:value_update, :updated, "flow", "value", %{data_report: [12.5, _]}}
      assert {:ok, %{data_report: [12.5, _]}} = NodeValues.get_value(node_id, "flow", "value")
    end

    test "a stale description_change message does not roll the node back", %{node_id: node_id} do
      connect(node_id, @desc_a)
      stale = change_description(node_id, raw_description("eq-b", @desc_b))
      assert_receive {:node_services_ready, ^node_id, _}, 5_000

      # The node moved on to description C before the message for B is handled
      current = node_state(node_id, raw_description("eq-c", @desc_a))
      FakeNodeStatem.put_state(node_id, current)
      broadcast("descriptive_data_change", {:description_change, topic(node_id), stale})
      flush_node_manager()

      assert NodeSupervisor.running_uuid(node_id) == current.uuid
    end

    test "pending values of the old services are written before they stop", %{node_id: node_id} do
      connect(node_id, @desc_a)
      [old_record] = active_records(node_id)

      temp_value =
        old_record.modules
        |> Enum.find(&(&1.name == "temp"))
        |> Map.fetch!(:parameters)
        |> Enum.find(&(&1.name == "value"))

      # Batched by the DB writer, not flushed yet
      send_value_update(node_id, "temp", "value", [42.5, %{t: 1_700_000_200.0}])
      :sys.get_state({:via, Registry, {Registry.NodeDBWriter, old_record.uuid}})

      change_description(node_id, raw_description("eq-b", @desc_b))
      assert_receive {:node_services_ready, ^node_id, _}, 5_000

      eventually(fn ->
        SecantService.SecNodes.Reading
        |> Ash.Query.filter(parameter_id == ^temp_value.id and value_float == 42.5)
        |> Ash.read!()
        |> Enum.any?()
      end)
    end
  end

  describe "reconnect with the same description" do
    test "keeps the services running", %{node_id: node_id} do
      state = connect(node_id, @desc_a)
      pid = NodeSupervisor.get_services_pid(node_id)

      # Plain reconnect: only the connection state changes, the uuid stays
      FakeNodeStatem.put_state(node_id, %{state | state: :initialized})
      broadcast("descriptive_data_change", {:description_change, topic(node_id), state})
      assert :ok = NodeManager.sync_nodes!()

      assert NodeSupervisor.get_services_pid(node_id) == pid
      refute_received {:node_services_ready, ^node_id, _}
    end

    test "restarts services when the state machine restarted (new uuid)", %{node_id: node_id} do
      old = connect(node_id, @desc_a)

      # A fresh uuid for the same description, e.g. after secant_client
      # restarted and lost its node table
      restarted = node_state(node_id, raw_description("eq-#{elem(node_id, 1)}", @desc_a))
      FakeNodeStatem.put_state(node_id, restarted)
      assert :ok = NodeManager.sync_nodes!()

      assert_receive {:node_services_ready, ^node_id, uuid}, 5_000
      assert uuid == restarted.uuid
      assert record_state(old.uuid) != :active
      assert served_modules(node_id) == sorted(@desc_a)
    end
  end

  describe "node removed from the client" do
    test "stops its services and archives its record", %{node_id: node_id} do
      state = connect(node_id, @desc_a)

      remove_node(node_id)
      assert :ok = NodeManager.sync_nodes!()

      assert_receive {:node_services_stopped, ^node_id}
      refute NodeSupervisor.services_running?(node_id)
      assert record_state(state.uuid) != :active
    end

    test "comes back with fresh services when rediscovered", %{node_id: node_id} do
      connect(node_id, @desc_a)
      remove_node(node_id)
      NodeManager.sync_nodes!()
      assert_receive {:node_services_stopped, ^node_id}

      state = connect(node_id, @desc_b)

      assert NodeSupervisor.running_uuid(node_id) == state.uuid
      assert served_modules(node_id) == sorted(@desc_b)
    end
  end

  describe "robustness" do
    # logs the expected timeout / start failure
    @tag :capture_log
    test "an unresponsive state machine neither blocks others nor loses its services",
         %{node_id: node_id} do
      slow = connect(node_id, @desc_a)
      other_id = unique_node_id()
      other = connect(other_id, @desc_b)

      # Stuck in a handshake: get_state does not answer within the timeout
      FakeNodeStatem.set_delay(node_id, 1_000)
      assert :ok = NodeManager.sync_nodes!()

      assert NodeSupervisor.running_uuid(node_id) == slow.uuid
      assert NodeSupervisor.running_uuid(other_id) == other.uuid
      refute_received {:node_services_stopped, _}
    end

    # logs the expected timeout / start failure
    @tag :capture_log
    test "a failed restart is retried until the new services run", %{node_id: node_id} do
      connect(node_id, @desc_a)

      # Something still holds the name of the DB writer of the new session,
      # so starting the new services fails...
      test_pid = self()
      new_uuid = Ecto.UUID.generate()

      blocker =
        spawn(fn ->
          Registry.register(Registry.NodeDBWriter, new_uuid, nil)
          send(test_pid, :registered)
          Process.sleep(:infinity)
        end)

      assert_receive :registered
      new = change_description(node_id, raw_description("eq-b", @desc_b), new_uuid)
      flush_node_manager()
      refute_received {:node_services_ready, ^node_id, _}

      # ...until it is gone: a retry completes the change
      Process.exit(blocker, :kill)
      assert_receive {:node_services_ready, ^node_id, uuid}, 5_000
      assert uuid == new.uuid
      assert served_modules(node_id) == sorted(@desc_b)
    end

    test "lookups on a node without services return errors instead of crashing",
         %{node_id: node_id} do
      assert NodeSupervisor.running_uuid(node_id) == nil
      assert {:error, :not_found} = NodeValues.get_snapshot(node_id)
      refute NodeSupervisor.services_running?(Ecto.UUID.generate())
    end
  end
end
