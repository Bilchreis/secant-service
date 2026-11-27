defmodule SecantService.PlotCacheTest do
  use ExUnit.Case, async: true

  import SecantService.NodeFixtures, only: [unique_node_id: 0, send_value_update: 4]

  alias SecantService.PlotCache
  alias SecantService.Topics

  setup do
    node_id = unique_node_id()
    node_db = %{node_id: node_id, modules: [%{name: "m", parameters: [%{name: "value"}]}]}
    Phoenix.PubSub.subscribe(SecantService.PubSub, Topics.plot_data(node_id))
    %{node_id: node_id, node_db: node_db}
  end

  test "a start or end of recording comes after the readings buffered before it", ctx do
    start_supervised!({PlotCache, ctx.node_db})
    send_value_update(ctx.node_id, "m", "value", [1.0, %{t: 1.0}])

    PlotCache.recording(ctx.node_id, :stopped, 5_000)

    # the first message is the batch
    assert_receive msg
    assert {:plot_data, [{"m", "value", [[1.0, %{t: 1.0}]]}]} = msg
    assert_receive {:recording, :stopped, 5_000}
  end

  test "without a running cache, a stop is published at once", ctx do
    PlotCache.recording(ctx.node_id, :stopped, 7_000)
    assert_receive {:recording, :stopped, 7_000}
  end
end
