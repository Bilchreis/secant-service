defmodule SecantServiceWeb.AcquisitionCardTest do
  @moduledoc """
  An AcquisitionController shows as one card with its channels (its
  `acquisition_channels` property). Each channel keeps its own status and
  shows its progress towards its goal.
  """
  use SecantServiceWeb.ConnCase, async: false, node: true

  @t 1_700_000_100.0

  setup %{conn: conn} do
    Phoenix.PubSub.subscribe(SecantService.PubSub, NodeManager.services_topic())
    node_id = unique_node_id()

    raw =
      raw_description("eq-acq-#{elem(node_id, 1)}", %{
        "ctrl" => ["status"],
        "timer" => ["value", "status", "goal", "goal_enable"],
        "counts" => ["value", "status"],
        "temp" => ["value", "status"]
      })
      |> put_module("ctrl", %{
        interface_classes: ["AcquisitionController"],
        acquisition_channels: %{t: "timer", monitor: "counts"}
      })
      |> put_module("timer", %{interface_classes: ["AcquisitionChannel", "Readable"]})
      |> put_module("counts", %{interface_classes: ["AcquisitionChannel", "Readable"]})
      |> put_accessible("ctrl", :go, %{datainfo: %{type: "command"}, description: "go"})
      |> put_accessible("ctrl", :stop, %{datainfo: %{type: "command"}, description: "stop"})
      |> put_accessible("timer", :goal_enable, %{
        datainfo: %{type: "bool"},
        readonly: false,
        description: "goal_enable"
      })

    connect_node(node_id, raw)
    assert_receive {:node_services_ready, ^node_id, _}, 5_000

    {:ok, view, _html} = live(conn, "/dashboard?node=#{topic(node_id)}&module=temp")
    render_async(view)

    {:ok, view: view, node_id: node_id}
  end

  defp put_module(raw, name, props),
    do: update_in(raw, [:modules, String.to_atom(name)], &Map.merge(&1, props))

  defp put_accessible(raw, name, param, data),
    do: put_in(raw, [:modules, String.to_atom(name), :accessibles, param], data)

  test "groups the channels into the controller's card", %{view: view} do
    assert has_element?(view, "#acq-ctrl #acq-channel-timer")
    assert has_element?(view, "#acq-ctrl #acq-channel-counts")
    assert has_element?(view, ~s(#acq-ctrl [id$=":ctrl:go"]))
    assert has_element?(view, ~s(#acq-ctrl [id$=":ctrl:stop"]))
    # no separate cards for the channels; unrelated modules keep theirs
    refute has_element?(view, "#card-timer")
    refute has_element?(view, "#card-counts")
    assert has_element?(view, "#card-temp")
    # the rail still lists every module
    assert has_element?(view, "#rail-timer")
  end

  test "each channel shows its own status", %{view: view, node_id: node_id} do
    send_value_update(node_id, "counts", "status", [[300, "counting"], %{t: @t}])

    eventually(fn -> has_element?(view, "#acq-channel-counts[data-status=busy]") end)
    refute has_element?(view, "#acq-channel-timer[data-status=busy]")
    refute has_element?(view, "#acq-ctrl[data-status=busy]")
  end

  test "shows the progress towards the goal", %{view: view, node_id: node_id} do
    send_value_update(node_id, "timer", "goal", [10.0, %{t: @t}])
    send_value_update(node_id, "timer", "value", [2.5, %{t: @t}])

    eventually(fn -> has_element?(view, "#acq-channel-timer [data-progress='0.25']") end)
    refute has_element?(view, "#acq-channel-counts [data-progress]")

    send_value_update(node_id, "timer", "goal_enable", [false, %{t: @t}])
    eventually(fn -> has_element?(view, "#acq-channel-timer [data-enabled=false]") end)
    refute has_element?(view, "#acq-channel-timer [role=progressbar]")
  end

  test "the inspector links controller and channels", %{view: view} do
    view |> element("#rail-ctrl") |> render_click()
    assert has_element?(view, "#acq-channel-links [phx-value-module=timer]", "t")

    view |> element("#rail-timer") |> render_click()
    assert has_element?(view, "#acq-controller-link [phx-value-module=ctrl]")
  end
end
