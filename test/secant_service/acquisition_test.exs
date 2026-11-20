defmodule SecantService.AcquisitionTest do
  use ExUnit.Case, async: true

  alias SecantService.Acquisition

  defp mod(name, classes \\ ["AcquisitionChannel", "Readable"], props \\ %{}),
    do: %{name: name, interface_classes: classes, custom_properties: props}

  defp controller(channels, key \\ "acquisition_channels"),
    do: mod("ctrl", ["AcquisitionController"], %{key => channels})

  test "channels lists roles with their modules, the time channel first" do
    ctrl = controller(%{"monitor" => "mon", "t" => "timer", "detector" => "gone"})
    modules = [ctrl, mod("mon"), mod("timer")]

    assert [{"t", "timer", %{name: "timer"}}, {"detector", "gone", nil}, {"monitor", "mon", _}] =
             Acquisition.channels(ctrl, modules)
  end

  test "reads the property with atom keys, as it comes straight from a description" do
    ctrl = controller(%{t: :timer}, :acquisition_channels)
    assert [{"t", "timer", %{name: "timer"}}] = Acquisition.channels(ctrl, [ctrl, mod("timer")])
  end

  test "channel_names holds only channels that exist and are claimed by a controller" do
    ctrl = controller(%{"t" => "timer", "x" => "gone"})
    modules = [ctrl, mod("timer"), mod("loose")]

    assert Acquisition.channel_names(modules) == MapSet.new(["timer"])
  end

  test "a module without the property is not a controller with channels" do
    assert Acquisition.channels(mod("ctrl", ["AcquisitionController"]), []) == []
    refute Acquisition.controller?(mod("timer"))
  end

  test "controller_of finds the controller and the role" do
    ctrl = controller(%{"t" => "timer"})
    assert {%{name: "ctrl"}, "t"} = Acquisition.controller_of(mod("timer"), [ctrl])
    assert Acquisition.controller_of(mod("other"), [ctrl]) == nil
  end

  describe "goal_progress" do
    test "is the share of the goal reached, capped to 0..1" do
      assert Acquisition.goal_progress(2.5, 10) == 0.25
      assert Acquisition.goal_progress(12, 10) == 1.0
      assert Acquisition.goal_progress(-1, 10) == 0.0
    end

    test "is nil for a disabled goal, a goal of zero or values that are not numbers" do
      assert Acquisition.goal_progress(2.5, 10, false) == nil
      assert Acquisition.goal_progress(2.5, 0) == nil
      assert Acquisition.goal_progress([1, 2], 10) == nil
      assert Acquisition.goal_progress(nil, 10) == nil
    end
  end
end
