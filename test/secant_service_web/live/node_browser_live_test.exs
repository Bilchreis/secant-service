defmodule SecantServiceWeb.NodeBrowserLiveTest do
  use SecantService.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SecantServiceWeb.Endpoint

  # A plot loads in an async task that queries the database; the default
  # 100 ms isn't enough on a busy machine.
  @async_timeout 2_000

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
      render_async(view, @async_timeout)

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

      render_async(view, @async_timeout)

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

      render_async(view, @async_timeout)
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

      render_async(view, @async_timeout)

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

      gap = [(1_000_000 + 100) * 1000, (1_000_000 + 400) * 1000, "disconnected"]

      render_hook(chart, "fetch-chart-window", %{
        "from" => 1_000_000_000,
        "to" => 1_000_600_000,
        "req" => 1,
        "gen" => 1,
        "envelope" => false
      })

      render_async(view, @async_timeout)

      assert_push_event(view, "window-chart-data-" <> ^id, %{
        gaps: [^gap, [_, nil, "disconnected"]]
      })

      render_hook(chart, "fetch-chart-overview", %{"gen" => 2, "envelope" => false})
      render_async(view, @async_timeout)

      assert_push_event(view, "overview-chart-data-" <> ^id, %{
        gaps: [^gap, [_, nil, "disconnected"]]
      })
    end

    test "an array plot's window reply takes its resolution from the drawn value alone" do
      alias SecantService.SecNodes.Reading.Storage

      node = generate(sec_node(equipment_id: "array cryo"))

      module =
        generate(
          sec_module(sec_node_id: node.uuid, name: "spec", interface_classes: ["Drivable"])
        )

      array = %{"type" => "array", "maxlen" => 10, "members" => %{"type" => "double"}}
      value = generate(parameter(name: "value", datainfo: array, module_id: module.id))
      target = generate(parameter(name: "target", datainfo: @double, module_id: module.id))
      t = fn s -> DateTime.from_unix!(1_000_000 + s, :second) end

      # few array readings, many target ones: the target alone would be thinned
      rows =
        for(i <- 0..9, do: Storage.to_row([i * 1.0, 1.0], value, t.(i * 10), %{})) ++
          for(i <- 0..4999, do: Storage.to_row(i * 1.0, target, t.(i), %{}))

      %Ash.BulkResult{status: :success} = SecantService.SecNodes.insert_readings(rows)

      SecantService.SecNodes.record_span!(%{
        id: Ecto.UUID.generate(),
        sec_node_id: node.uuid,
        started_at: t.(0),
        alive_until: t.(30),
        ended_at: t.(30),
        end_reason: :disconnected
      })

      {:ok, view, _html} = live(build_conn(), "/browse/node/#{node.uuid}?module=spec")
      render_async(view, @async_timeout)
      id = "hplot:#{node.uuid}:spec:module"
      chart = with_target(view, ~s([id="history-#{id}"]))

      render_hook(chart, "fetch-chart-window", %{
        "from" => 1_000_000_000,
        "to" => 1_005_000_000,
        "req" => 1,
        "gen" => 1,
        "envelope" => false
      })

      render_async(view, @async_timeout)

      assert_push_event(view, "window-chart-data-" <> ^id, %{
        aggregated: false,
        gaps: [[_, nil, "disconnected"]]
      })
    end
  end

  describe "system module plots" do
    alias SecantService.SecNodes.Reading.Storage
    alias SecantServiceWeb.TestSystems

    @mfc %{
      "type" => "struct",
      "members" => %{
        "composition" => %{
          "type" => "array",
          "maxlen" => 4,
          "members" => %{"type" => "double", "unit" => "%"}
        },
        "gas_list" => %{"type" => "array", "maxlen" => 4, "members" => %{"type" => "string"}},
        "total_flow" => %{"type" => "double", "unit" => "ml/min"}
      }
    }
    @spectrum %{"type" => "array", "maxlen" => 100, "members" => %{"type" => "double"}}

    setup do
      previous = Application.get_env(:secant_service, :systems)
      on_exit(fn -> Application.put_env(:secant_service, :systems, previous) end)

      Application.put_env(:secant_service, :systems, [
        TestSystems.MfcGroup,
        TestSystems.MassSpec,
        TestSystems.MissingMass
      ])

      :ok
    end

    # a recorded node whose module `name` has `params` and is bound as role
    # `role` of a `system` entry; `readings` per parameter, a second apart
    defp recorded(name, system, role, params, readings) do
      systems = %{"sys" => %{"system" => system, "modules" => %{role => name}}}

      node =
        generate(
          sec_node(equipment_id: "sys #{name}", custom_properties: %{"systems" => systems})
        )

      module =
        generate(sec_module(sec_node_id: node.uuid, name: name, interface_classes: ["Readable"]))

      params =
        Map.new(params, fn {pname, datainfo} ->
          {pname, generate(parameter(name: pname, datainfo: datainfo, module_id: module.id))}
        end)

      t = fn s -> DateTime.from_unix!(1_000_000 + s, :second) end

      rows =
        for {pname, values} <- readings,
            {value, i} <- Enum.with_index(values),
            do: Storage.to_row(value, params[pname], t.(i), %{})

      if rows != [],
        do: %Ash.BulkResult{status: :success} = SecantService.SecNodes.insert_readings(rows)

      {:ok, view, _html} = live(build_conn(), "/browse/node/#{node.uuid}?module=#{name}")
      render_async(view, @async_timeout)
      id = "hplot:#{node.uuid}:#{name}:module"
      {view, id, with_target(view, ~s([id="history-#{id}"]))}
    end

    defp mfc(gases),
      do: %{"composition" => [10.0, 20.0, 30.0, 40.0], "gas_list" => gases, "total_flow" => 2.0}

    test "the stored session's module plot draws the role's traces, through every fetch" do
      {view, id, chart} =
        recorded("mfc", "MfcGroup:0", "group", [{"value", @mfc}], %{
          "value" => [mfc(["N2", "H2", "CO", "O2"]), mfc(["N2", "H2", "CO", "O2"])]
        })

      assert has_element?(view, "#system-membership-sys", "group")

      assert_push_event(view, "echarts-data-" <> ^id, %{option: option})
      assert Enum.map(option.series, & &1.name) |> length() == 5
      assert Enum.map(option.series, &Map.get(&1, :_label)) == ["N2", "H2", "CO", "O2", nil]

      window = %{"from" => 1_000_000_000, "to" => 1_000_010_000, "req" => 1, "gen" => 1}
      render_hook(chart, "fetch-chart-window", Map.put(window, "envelope", false))
      render_async(view, @async_timeout)
      assert_push_event(view, "window-chart-data-" <> ^id, %{seriesUpdates: updates})
      assert Enum.map(updates, & &1.seriesIndex) == [0, 1, 2, 3, 4]

      render_hook(chart, "fetch-chart-overview", %{"gen" => 2, "envelope" => false})
      render_async(view, @async_timeout)
      assert_push_event(view, "overview-chart-data-" <> ^id, %{seriesUpdates: updates})
      assert length(updates) == 5

      render_hook(chart, "fetch-chart-range", %{"from" => nil, "to" => 1_000_010_000, "req" => 3})
      render_async(view, @async_timeout)
      assert_push_event(view, "prepend-chart-data-" <> ^id, %{seriesUpdates: updates})
      assert length(updates) == 5
    end

    test "a mass spectrum's heatmap index is labelled by mass" do
      {view, id, _chart} =
        recorded(
          "ms",
          "MassSpec:0",
          "spectrometer",
          [{"value", @spectrum}, {"_mass", @spectrum}],
          %{
            "value" => [[0.1, 0.2, 0.3]],
            "_mass" => [[1.0, 2.0, 28.0]]
          }
        )

      assert_push_event(view, "echarts-data-" <> ^id, %{option: option})
      assert option._indexLabels == ["m/z 1", "m/z 2", "m/z 28"]
    end

    test "a module whose value can't be plotted shows its table, with or without a role" do
      string = %{"type" => "string"}

      {view, id, _chart} =
        recorded(
          "strmod",
          "MissingMass:0",
          "spectrometer",
          [{"value", string}, {"spectrum", @spectrum}, {"_mass", @spectrum}],
          %{"_mass" => [[1.0, 2.0]], "value" => ["a"]}
        )

      # the role's only trace picks a mass that isn't there: the table,
      # loaded after the plot came back empty
      render_async(view, @async_timeout)
      assert has_element?(view, ~s([id="#{id}-table-wrap"]))

      {view, id, _chart} =
        recorded("plain", "Unknown:0", "x", [{"value", string}], %{"value" => ["a"]})

      assert has_element?(view, ~s([id="#{id}-table-wrap"]))
    end
  end
end
