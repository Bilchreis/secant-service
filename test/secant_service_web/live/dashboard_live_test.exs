defmodule SecantServiceWeb.DashboardLiveTest do
  @moduledoc """
  The dashboard must follow a node through description changes: show the new
  module tree, drop removed modules and keep receiving live values.
  """
  use SecantServiceWeb.ConnCase, async: false, node: true

  @desc_a %{"temp" => ["value", "status", "target"], "press" => ["value", "status"]}
  @desc_b %{"temp" => ["value", "status", "target"], "flow" => ["value", "status"]}

  setup %{conn: conn} do
    Phoenix.PubSub.subscribe(SecantService.PubSub, NodeManager.services_topic())
    node_id = unique_node_id()
    {:ok, conn: conn, node_id: node_id, path: "/dashboard?node=#{topic(node_id)}"}
  end

  defp connect_and_wait(node_id, modules) do
    state = connect_node(node_id, raw_description("eq-#{elem(node_id, 1)}", modules))
    assert_receive {:node_services_ready, ^node_id, _}, 5_000
    state
  end

  # Waits for the history queries of the page: a reload cancels unfinished
  # ones, and a query killed mid-flight breaks the shared sandbox connection.
  defp open_dashboard(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view)
    view
  end

  # The view handles messages in order, so a render after the broadcast has
  # seen everything broadcast before it.
  defp rerender(view), do: render(view) && view

  test "shows the modules of the node", %{conn: conn, node_id: node_id, path: path} do
    state = connect_and_wait(node_id, @desc_a)
    view = open_dashboard(conn, path)

    assert has_element?(view, "#rail-temp")
    assert has_element?(view, "#rail-press")
    assert has_element?(view, "#uuid-#{state.uuid}")
  end

  test "follows a reconnect with a changed description",
       %{conn: conn, node_id: node_id, path: path} do
    old = connect_and_wait(node_id, @desc_a)
    view = open_dashboard(conn, path)

    new = change_description(node_id, raw_description("eq-b", @desc_b))
    assert_receive {:node_services_ready, ^node_id, _}, 5_000
    rerender(view)

    assert has_element?(view, "#rail-flow")
    refute has_element?(view, "#rail-press")
    assert has_element?(view, "#uuid-#{new.uuid}")
    refute has_element?(view, "#uuid-#{old.uuid}")
    # The tab of the shown node stays highlighted (compared by node, not uuid)
    assert has_element?(view, "#node-tab-#{escape(topic(node_id))}.border-primary")
  end

  test "keeps receiving live values after the services restarted",
       %{conn: conn, node_id: node_id, path: path} do
    connect_and_wait(node_id, @desc_a)
    view = open_dashboard(conn, path)

    change_description(node_id, raw_description("eq-b", @desc_b))
    assert_receive {:node_services_ready, ^node_id, _}, 5_000
    rerender(view)
    refute has_element?(view, "#status-summary", "busy")

    # A status update on a module that only exists in the new description
    send_value_update(node_id, "flow", "status", [[300, "moving"], %{t: 1_700_000_300.0}])

    eventually(fn -> has_element?(view, "#status-summary", "1 busy") end)
  end

  test "shows a node whose services come up after the page was opened",
       %{conn: conn, node_id: node_id, path: path} do
    # Known to the client, but the service side has not caught up yet
    raw = raw_description("eq-late", @desc_a)
    seed_node_table(node_id, raw)
    state = node_state(node_id, raw)
    start_supervised!({FakeNodeStatem, {node_id, state, []}})

    view = open_dashboard(conn, path)
    refute has_element?(view, "#rail-temp")

    broadcast("new_node", {:new_node, topic(node_id), state})
    assert_receive {:node_services_ready, ^node_id, _}, 5_000

    assert has_element?(rerender(view), "#rail-temp")
  end

  test "stays usable when a plotted parameter disappears",
       %{conn: conn, node_id: node_id, path: path} do
    connect_and_wait(node_id, @desc_a)
    view = open_dashboard(conn, path <> "&module=press")
    render_hook(view, "plot_parameter", %{"param" => "value"})
    render_async(view)

    change_description(node_id, raw_description("eq-b", @desc_b))
    assert_receive {:node_services_ready, ^node_id, _}, 5_000
    rerender(view)

    refute has_element?(view, "#rail-press")
    assert has_element?(view, "#inspector")
  end

  test "a burst of value updates ends on the latest value",
       %{conn: conn, node_id: node_id, path: path} do
    connect_and_wait(node_id, @desc_a)
    view = open_dashboard(conn, path)

    for i <- 1..50,
        do: send_value_update(node_id, "temp", "value", [i + 0.5, %{t: 1_700_000_000.0 + i}])

    assert eventually(fn -> render(view) =~ "50.5" end)
    refute render(view) =~ "49.5"
  end

  test "a status error report is shown and keeps the page alive",
       %{conn: conn, node_id: {host, port} = node_id, path: path} do
    connect_and_wait(node_id, @desc_a)
    view = open_dashboard(conn, path)

    for _ <- 1..3 do
      Phoenix.PubSub.broadcast(
        :secant_client_pubsub,
        "error_update:#{host}:#{port}",
        {:error_update, "temp", "status", ["HardwareError", "sensor unplugged", %{}]}
      )
    end

    assert eventually(fn -> render(view) =~ "HardwareError: sensor unplugged" end)

    # a remount reads the error from the services' table
    assert {:ok, _view, _html} = live(conn, path)
  end

  test "a malformed node link does not crash the page", %{conn: conn, node_id: node_id} do
    connect_and_wait(node_id, @desc_a)

    for bad <- ["a:b", "nohost", ":1234", "host:99999"] do
      assert {:ok, _view, _html} = live(conn, "/dashboard?node=" <> URI.encode_www_form(bad))
    end
  end

  test "connect-node rejects an invalid port", %{conn: conn, node_id: node_id, path: path} do
    connect_and_wait(node_id, @desc_a)
    view = open_dashboard(conn, path)

    render_hook(view, "connect-node", %{"host" => "localhost", "port" => "abc"})
    render_hook(view, "connect-node", %{"host" => "", "port" => "10800"})

    assert Process.alive?(view.pid)
  end

  # "127.0.0.1:1234" -> CSS-safe id selector part
  defp escape(id), do: String.replace(id, ~r/([.:])/, "\\\\\\1")
end
