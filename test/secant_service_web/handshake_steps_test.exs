defmodule SecantServiceWeb.HandshakeStepsTest do
  use ExUnit.Case, async: true

  alias SecantServiceWeb.DashboardComponents.NodeTabs

  defp statuses(node) do
    node |> NodeTabs.handshake_steps() |> Enum.map(&{&1.id, &1.status})
  end

  test "a node that refuses the connection hangs at connect" do
    assert statuses(%{state: :disconnected, idn: nil}) ==
             [connect: :failed, identify: :pending, describe: :pending, record: :pending]
  end

  test "a connected node is identifying, then describing" do
    assert statuses(%{state: :connected, idn: nil}) ==
             [connect: :done, identify: :current, describe: :pending, record: :pending]

    assert statuses(%{state: :connected, idn: %{version: "v1.0"}}) ==
             [connect: :done, identify: :done, describe: :current, record: :pending]
  end

  test "a node that stops answering hangs at the request it did not answer" do
    assert statuses(%{state: :could_not_initialize, idn: nil}) ==
             [connect: :done, identify: :failed, describe: :pending, record: :pending]

    assert statuses(%{state: :could_not_initialize, idn: %{version: "v1.0"}}) ==
             [connect: :done, identify: :done, describe: :failed, record: :pending]
  end

  test "a described node is being stored" do
    assert statuses(%{state: :initialized, idn: %{version: "v1.0"}, equipment_id: "cryo"}) ==
             [connect: :done, identify: :done, describe: :done, record: :current]
  end

  test "a discovered node starts with a done discover step" do
    assert statuses(%{state: :disconnected, idn: nil, manual: false}) ==
             [
               discover: :done,
               connect: :failed,
               identify: :pending,
               describe: :pending,
               record: :pending
             ]

    refute {:discover, :done} in statuses(%{state: :disconnected, idn: nil, manual: true})
  end

  test "an unknown node hangs at connect" do
    assert [{:connect, :failed} | _] = statuses(nil)
  end
end
