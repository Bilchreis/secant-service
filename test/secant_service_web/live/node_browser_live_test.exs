defmodule SecantServiceWeb.NodeBrowserLiveTest do
  use SecantService.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SecantServiceWeb.Endpoint

  test "the node header links to the NeXus export of the node" do
    node = generate(sec_node(equipment_id: "test cryo", description: "test cryostat"))

    {:ok, view, _html} = live(build_conn(), "/browse/node/#{node.uuid}")

    assert has_element?(view, ~s(#nexus-export[href="/export/node/#{node.uuid}"][download]))
  end

  describe "historical plot envelopes" do
    @double %{"type" => "double", "unit" => "K"}

    # a node with a Drivable module, its page open on that module's plot
    defp drivable_plot do
      node = generate(sec_node(equipment_id: "envelope cryo"))

      module =
        generate(
          sec_module(sec_node_id: node.uuid, name: "temp", interface_classes: ["Drivable"])
        )

      for name <- ["value", "target"],
          do: generate(parameter(name: name, datainfo: @double, module_id: module.id))

      {:ok, view, _html} = live(build_conn(), "/browse/node/#{node.uuid}?module=temp")
      render_async(view)

      id = "hplot:#{node.uuid}:temp:module"
      {view, id, with_target(view, ~s([id="history-#{id}"]))}
    end

    test "the toggle slot sits next to the array-mode group" do
      {view, id, _chart} = drivable_plot()
      assert has_element?(view, ~s([id="envelope-toggle-#{id}"][phx-update="ignore"]))
    end

    test "a window fetch echoes its generation and the envelope it applied" do
      {view, id, chart} = drivable_plot()

      render_hook(chart, "fetch-chart-window", %{
        "from" => 0,
        "to" => 1_000,
        "req" => 1,
        "gen" => 3,
        "envelope" => true
      })

      render_async(view)

      assert_push_event(view, "window-chart-data-" <> ^id, %{
        gen: 3,
        envelope: true,
        envelopes: []
      })

      render_hook(chart, "fetch-chart-window", %{
        "from" => 0,
        "to" => 1_000,
        "req" => 2,
        "gen" => 4,
        "envelope" => "yes"
      })

      render_async(view)
      assert_push_event(view, "window-chart-data-" <> ^id, %{gen: 4, envelope: false})
    end

    test "an overview reload runs beside a window fetch, and both answer" do
      {view, id, chart} = drivable_plot()

      render_hook(chart, "fetch-chart-overview", %{"gen" => 5, "envelope" => true})

      render_hook(chart, "fetch-chart-window", %{
        "from" => 0,
        "to" => 1_000,
        "req" => 1,
        "gen" => 5,
        "envelope" => true
      })

      render_async(view)

      assert_push_event(view, "overview-chart-data-" <> ^id, %{
        gen: 5,
        envelope: true,
        envelopes: [],
        seriesUpdates: _
      })

      assert_push_event(view, "window-chart-data-" <> ^id, %{gen: 5})
    end

    test "window and overview replies carry the session's gaps" do
      {view, id, chart} = drivable_plot()
      [node] = Ash.read!(SecantService.SecNodes.SecNode)
      t = fn s -> DateTime.from_unix!(1_000_000 + s, :second) end

      for {from, to} <- [{0, 100}, {400, 500}] do
        SecantService.SecNodes.record_span!(%{
          id: Ecto.UUID.generate(),
          sec_node_id: node.uuid,
          started_at: t.(from),
          alive_until: t.(to),
          ended_at: t.(to),
          end_reason: :disconnected
        })
      end

      gap = [(1_000_000 + 100) * 1000, (1_000_000 + 400) * 1000]

      render_hook(chart, "fetch-chart-window", %{
        "from" => 1_000_000_000,
        "to" => 1_000_600_000,
        "req" => 1,
        "gen" => 1,
        "envelope" => false
      })

      render_async(view)
      assert_push_event(view, "window-chart-data-" <> ^id, %{gaps: [^gap, [_, nil]]})

      render_hook(chart, "fetch-chart-overview", %{"gen" => 2, "envelope" => false})
      render_async(view)
      assert_push_event(view, "overview-chart-data-" <> ^id, %{gaps: [^gap, [_, nil]]})
    end
  end
end
