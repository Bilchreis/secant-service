defmodule SecantService.NodeValuesTest do
  @moduledoc """
  Error reports from the node must be kept next to the value they belong to,
  and must never take the node services down.
  """
  use SecantService.NodeCase, async: false

  @desc %{"temp" => ["value", "status", "target"]}

  setup do
    Phoenix.PubSub.subscribe(SecantService.PubSub, SecantService.Topics.node_services())
    node_id = unique_node_id()
    connect_node(node_id, raw_description("eq-#{elem(node_id, 1)}", @desc))
    assert_receive {:node_services_ready, ^node_id, _}, 5_000

    Phoenix.PubSub.subscribe(SecantService.PubSub, SecantService.Topics.processed_values(node_id))
    {:ok, node_id: node_id, values_pid: values_pid(node_id)}
  end

  defp values_pid(node_id) do
    [{pid, _}] = Registry.lookup(Registry.NodeValues, node_id)
    pid
  end

  defp send_error_update({host, port}, module, param, error_report) do
    Phoenix.PubSub.broadcast(
      :secant_client_pubsub,
      "error_update:#{host}:#{port}",
      {:error_update, module, param, error_report}
    )
  end

  @error ["CommunicationFailed", "sensor unplugged", %{t: 1_700_000_200.0}]

  test "repeated error reports leave the node services running",
       %{node_id: node_id, values_pid: pid} do
    for _ <- 1..5, do: send_error_update(node_id, "temp", "status", @error)
    send_error_update(node_id, "temp", "value", @error)

    assert_receive {:value_updates, _, %{{"temp", "value"} => %{error_report: @error}}}, 1_000
    assert values_pid(node_id) == pid
    assert NodeSupervisor.services_running?(node_id)
  end

  test "an error report on status is stored and does not crash the services",
       %{node_id: node_id, values_pid: pid} do
    send_error_update(node_id, "temp", "status", @error)

    assert_receive {:value_updates, _, %{{"temp", "status"} => %{error_report: @error}}}
    assert {:ok, %{error_report: @error}} = NodeValues.get_value(node_id, "temp", "status")
    assert Process.alive?(pid)
    assert values_pid(node_id) == pid
  end

  test "an error report without qualifiers is stored too", %{node_id: node_id} do
    send_error_update(node_id, "temp", "status", ["HardwareError", "no answer"])

    assert_receive {:value_updates, _,
                    %{{"temp", "status"} => %{error_report: ["HardwareError", "no answer"]}}}
  end

  test "an error report on an ordinary parameter is cleared by the next value",
       %{node_id: node_id} do
    send_error_update(node_id, "temp", "value", @error)
    assert_receive {:value_updates, _, %{{"temp", "value"} => %{error_report: @error}}}

    # a second batch: the publish timer is armed again after the first
    send_value_update(node_id, "temp", "value", [4.2, %{t: 1_700_000_300.0}])
    assert_receive {:value_updates, _, %{{"temp", "value"} => %{data_report: [4.2, _]}}}

    assert {:ok, value} = NodeValues.get_value(node_id, "temp", "value")
    refute Map.has_key?(value, :error_report)
    assert value.data_report == [4.2, %{t: 1_700_000_300.0}]
  end

  test "an unchanged value is not broadcast again", %{node_id: node_id} do
    send_value_update(node_id, "temp", "value", [1.5, %{t: 1_700_000_400.0}])
    assert_receive {:value_updates, _, %{{"temp", "value"} => _}}

    # same value, newer timestamp
    send_value_update(node_id, "temp", "value", [1.5, %{t: 1_700_000_401.0}])
    refute_receive {:value_updates, _, %{{"temp", "value"} => _}}, 200
  end

  test "an error repeated with only a new timestamp is not broadcast again",
       %{node_id: node_id} do
    send_error_update(node_id, "temp", "value", @error)
    assert_receive {:value_updates, _, %{{"temp", "value"} => _}}

    [cls, msg, _qualifiers] = @error
    send_error_update(node_id, "temp", "value", [cls, msg, %{t: 1_700_000_201.0}])
    refute_receive {:value_updates, _, %{{"temp", "value"} => _}}, 200

    send_error_update(node_id, "temp", "value", [cls, "sensor broken", %{t: 1_700_000_202.0}])

    assert_receive {:value_updates, _,
                    %{{"temp", "value"} => %{error_report: [_, "sensor broken", _]}}}
  end

  # Runs `send_updates` while NodeValues is suspended, so all the updates are
  # handled back to back on resume, inside one publish interval. The interval
  # is longer than the test default, so a slow machine cannot split the batch.
  defp in_one_interval(pid, send_updates) do
    previous = Application.fetch_env!(:secant_service, :values_publish_interval)
    Application.put_env(:secant_service, :values_publish_interval, 200)
    on_exit(fn -> Application.put_env(:secant_service, :values_publish_interval, previous) end)
    :sys.suspend(pid)
    send_updates.()
    :sys.resume(pid)
  end

  test "a value and then an error inside one interval are published together",
       %{node_id: node_id, values_pid: pid} do
    in_one_interval(pid, fn ->
      send_value_update(node_id, "temp", "value", [6.0, %{t: 1_700_000_600.0}])
      send_error_update(node_id, "temp", "value", @error)
    end)

    assert_receive {:value_updates, ^node_id, batch}, 1_000
    assert %{data_report: [6.0, _], error_report: @error} = batch[{"temp", "value"}]
    assert {:ok, current} = NodeValues.get_value(node_id, "temp", "value")

    assert Map.take(current, [:data_report, :error_report]) ==
             Map.take(batch[{"temp", "value"}], [:data_report, :error_report])
  end

  test "changes are published in batches, latest per parameter",
       %{node_id: node_id, values_pid: pid} do
    in_one_interval(pid, fn ->
      for {v, t} <- [{1.0, 1}, {2.0, 2}, {3.0, 3}] do
        send_value_update(node_id, "temp", "value", [v, %{t: 1_700_000_500.0 + t}])
      end

      send_value_update(node_id, "temp", "target", [5.0, %{t: 1_700_000_504.0}])
    end)

    assert_receive {:value_updates, ^node_id, batch}, 1_000
    assert %{data_report: [3.0, _]} = batch[{"temp", "value"}]
    assert %{data_report: [5.0, _]} = batch[{"temp", "target"}]
    refute_receive {:value_updates, _, _}, 100
  end
end
