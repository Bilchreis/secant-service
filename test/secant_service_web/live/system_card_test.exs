defmodule SecantServiceWeb.SystemCardTest do
  @moduledoc """
  Modules bound to a role of a configured SECoP system get the role's custom
  card on the dashboard, inside the shared card chrome; every other module
  keeps the generic card. The module panel names the module's systems.
  """
  use SecantServiceWeb.ConnCase, async: false, node: true

  alias SecantServiceWeb.TestSystems.MfcGroup
  alias SecantServiceWeb.TestSystems.PowerSupply

  @t 1_700_000_100.0

  @modules %{
    "magcur_x" => ~w(value status target control_active voltage_limit power_limit),
    "magvolt_x" => ~w(value status),
    "magcur_old" => ~w(value control_active),
    "magcur_nc" => ~w(value),
    "magres_x" => ~w(value),
    "mfc" => ~w(value),
    "ctrl" => ~w(status),
    "ch" => ~w(value status),
    "plain" => ~w(value status)
  }

  @systems %{
    mag5t_x: %{
      system: "PowerSupply:0",
      description: "X axis",
      modules: %{current: "magcur_x", voltage: "magvolt_x", resistance: "magres_x"}
    },
    mag5t: %{system: "VectorMagnet:0", modules: %{X: "mag5t_x"}},
    old_ps: %{system: "PowerSupply:1", modules: %{current: "magcur_old"}},
    nc_ps: %{system: "PowerSupply:0", modules: %{current: "magcur_nc"}},
    acq_ps: %{system: "PowerSupply:0", modules: %{voltage: "ch"}},
    mfcs: %{system: "MfcGroup:0", modules: %{group: "mfc"}}
  }

  setup %{conn: conn} do
    previous = Application.get_env(:secant_service, :systems)
    on_exit(fn -> Application.put_env(:secant_service, :systems, previous) end)
    Application.put_env(:secant_service, :systems, [PowerSupply, MfcGroup])

    Phoenix.PubSub.subscribe(SecantService.PubSub, SecantService.Topics.node_services())
    node_id = unique_node_id()
    {:ok, conn: conn, node_id: node_id, path: "/dashboard?node=#{topic(node_id)}"}
  end

  def description(node_id, systems \\ @systems) do
    "eq-sys-#{elem(node_id, 1)}"
    |> raw_description(@modules)
    |> then(&if(systems, do: put_systems(&1, systems), else: &1))
    |> put_module("ctrl", %{
      interface_classes: ["AcquisitionController"],
      acquisition_channels: %{t: "ch"}
    })
    |> put_module("ch", %{interface_classes: ["AcquisitionChannel", "Readable"]})
    |> put_accessible("magcur_x", :control_active, %{
      datainfo: %{type: "bool"},
      readonly: false,
      description: "current mode"
    })
  end

  defp put_module(raw, name, props),
    do: update_in(raw, [:modules, String.to_atom(name)], &Map.merge(&1, props))

  defp put_accessible(raw, name, param, data),
    do: put_in(raw, [:modules, String.to_atom(name), :accessibles, param], data)

  def connect_and_open(conn, node_id, path, raw) do
    connect_node(node_id, raw)
    assert_receive {:node_services_ready, ^node_id, _}, 5_000
    {:ok, view, _html} = live(conn, path)
    render_async(view)
    view
  end

  defp open(ctx, raw \\ nil),
    do: connect_and_open(ctx.conn, ctx.node_id, ctx.path, raw || description(ctx.node_id))

  # the session uuid of the connected node, for plot ids
  defp with_uuid(ctx) do
    {:ok, {node, _values}} = SecantService.NodeValues.get_snapshot(ctx.node_id)
    Map.put(ctx, :uuid, node.uuid)
  end

  test "a matched module gets its role's card body inside the shared chrome", ctx do
    view = open(ctx)

    assert has_element?(
             view,
             ~s(#card-magcur_x[data-system="PowerSupply:0"][data-role="current"] #sys-body-magcur_x)
           )

    assert has_element?(view, "#card-magcur_x-system", "PowerSupply:0 · current")
    assert has_element?(view, ~s(#card-magcur_x [id$=":magcur_x:control_active"]))
    # the role's body replaces the generic target and sparkline
    refute has_element?(view, ~s(#card-magcur_x [id$=":magcur_x:target"]))
    assert has_element?(view, ~s(#card-magvolt_x[data-role="voltage"] #sys-body-magvolt_x))
  end

  test "modules that match nothing keep the generic card", ctx do
    view = open(ctx)

    # unhandled version, role without a module, missing required parameter
    for name <- ~w(magcur_old magres_x magcur_nc plain) do
      assert has_element?(view, "#card-#{name}")
      refute has_element?(view, "#card-#{name}[data-system]")
      refute has_element?(view, "#sys-body-#{name}")
    end
  end

  test "with no systems configured every module keeps the generic card", ctx do
    Application.put_env(:secant_service, :systems, [])
    view = open(ctx)

    assert has_element?(view, "#card-magcur_x")
    refute has_element?(view, "#card-magcur_x[data-system]")
    refute has_element?(view, "#sys-body-magcur_x")
  end

  test "a role with a plot and no card keeps the generic card, without a badge", ctx do
    view = open(ctx)

    assert has_element?(view, "#card-mfc")
    refute has_element?(view, "#card-mfc[data-system]")
    refute has_element?(view, "#card-mfc-system")
  end

  test "an acquisition channel bound in a system stays in its controller's card", ctx do
    view = open(ctx)

    assert has_element?(view, "#acq-ctrl #acq-channel-ch")
    refute has_element?(view, "#card-ch")
  end

  test "a custom card is selected and goes stale like a generic one", ctx do
    view = open(ctx)

    view |> element("#card-magcur_x header button") |> render_click()
    assert has_element?(view, "#card-magcur_x.border-primary")

    broadcast("secop_conn_state", {:conn_state, topic(ctx.node_id), false})
    render(view)
    assert has_element?(view, ~s(#card-magcur_x[data-stale="true"].border-dashed))
  end

  test "a new description that adds the system switches to the custom card", ctx do
    view = open(ctx, description(ctx.node_id, nil))
    refute has_element?(view, "#sys-body-magcur_x")

    change_description(ctx.node_id, description(ctx.node_id))
    node_id = ctx.node_id
    assert_receive {:node_services_ready, ^node_id, _}, 5_000
    render(view)

    assert has_element?(view, "#card-magcur_x #sys-body-magcur_x")
  end

  test "a malformed systems property leaves every card generic", ctx do
    view = open(ctx, description(ctx.node_id, ["PowerSupply"]))

    assert has_element?(view, "#card-magcur_x")
    refute has_element?(view, "[data-system]")
  end

  describe "live values" do
    test "card_route sends shown parameters that no other route reaches" do
      shown = MapSet.new([{"m", "control_active"}, {"m", "goal"}, {"m", "value"}])
      route = &SecantServiceWeb.DashboardLive.Index.card_route/3

      assert route.(shown, "m", "control_active")
      assert route.(shown, "m", "goal")
      # value and target already reach the card's displays
      refute route.(shown, "m", "value")
      refute route.(shown, "m", "target")
      refute route.(shown, "m", "voltage_limit")
      refute route.(shown, "other", "control_active")
    end

    test "a shown parameter updates live, and starts with the current value", ctx do
      view = open(ctx)
      refute has_element?(view, "#sys-body-magcur_x", "true")

      send_value_update(ctx.node_id, "magcur_x", "control_active", [true, %{t: @t}])
      eventually(fn -> render(view) && has_element?(view, "#sys-body-magcur_x", "true") end)

      # a new page shows the current value on its first render
      {:ok, fresh, _html} = live(ctx.conn, ctx.path)
      render_async(fresh)
      assert has_element?(fresh, "#sys-body-magcur_x", "true")
    end
  end

  describe "module plot" do
    defp plot_id(ctx, module, param \\ "module"),
      do: "plot:#{with_uuid(ctx).uuid}:#{topic(ctx.node_id)}:#{module}:#{param}"

    defp open_module(ctx, module) do
      state_view = open(ctx)
      state_view |> element("#rail-#{module}") |> render_click()
      render_async(state_view)
      state_view
    end

    defp option_series(option), do: Enum.map(option.series, & &1.name)

    test "the matched role's lines replace the module plot", ctx do
      view = open_module(ctx, "magcur_x")
      id = plot_id(ctx, "magcur_x")

      assert_push_event(view, "echarts-data-" <> ^id, %{option: option})
      assert option_series(option) == ~w(value target voltage_limit power_limit)
      assert option.legend.selected == %{"power_limit" => false}
      assert [_left, %{position: "right"}] = option.yAxis
    end

    test "a reading of a custom trace extends it live", ctx do
      view = open_module(ctx, "magcur_x")
      id = plot_id(ctx, "magcur_x")
      assert_push_event(view, "echarts-data-" <> ^id, %{option: _})

      send_value_update(ctx.node_id, "magcur_x", "voltage_limit", [12.0, %{t: @t}])
      # the broadcast is in the cache's mailbox before this call
      _ = SecantService.PlotCache.flush(ctx.node_id)
      render(view)

      assert_push_event(view, "extend-chart-" <> ^id, %{
        seriesUpdates: [%{seriesIndex: 2} = update]
      })

      assert [[_, 12.0]] = update.data
    end

    test "a role without a plot, and a parameter's own plot, stay generic", ctx do
      view = open_module(ctx, "magvolt_x")
      id = plot_id(ctx, "magvolt_x")
      assert_push_event(view, "echarts-data-" <> ^id, %{option: option})
      assert option_series(option) == ["value"]

      view |> element("#rail-magcur_x") |> render_click()
      render_async(view)
      render_click(view, "plot_parameter", %{"param" => "voltage_limit"})
      render_async(view)

      id = plot_id(ctx, "magcur_x", "voltage_limit")
      assert_push_event(view, "echarts-data-" <> ^id, %{option: option})
      assert option_series(option) == ["value"]
    end
  end

  test "the module panel names the module's systems and their parents", ctx do
    view = open(ctx)

    view |> element("#rail-magcur_x") |> render_click()
    assert has_element?(view, "#system-membership-mag5t_x", "current")
    assert has_element?(view, "#system-membership-mag5t_x", "PowerSupply:0")
    assert has_element?(view, "#system-membership-mag5t_x", "VectorMagnet:0")

    view |> element("#rail-plain") |> render_click()
    refute has_element?(view, "#system-membership")
  end
end
