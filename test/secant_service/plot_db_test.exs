defmodule SecantService.PlotDBTest do
  @moduledoc """
  Plots are built from the database only. A session without readings plots
  empty; nothing is read from the device at that address.
  """
  use SecantService.DataCase, async: false

  alias SecantService.PlotDB

  # No node is connected at this address, so any read from the device fails.
  defp create_module(interface_classes, params) do
    node = generate(sec_node(host: "192.0.2.1"))
    module = generate(sec_module(sec_node_id: node.uuid, interface_classes: interface_classes))

    for {name, datainfo} <- params do
      generate(parameter(name: name, datainfo: datainfo, module_id: module.id))
    end

    Ash.load!(module, :parameters)
  end

  @double %{"type" => "double", "unit" => "K"}

  test "a readable without readings plots empty in history" do
    module = create_module(["Readable"], [{"value", @double}])

    assert %{plottable: true, plot_available: false} = PlotDB.module_plot(module, :historical)
  end

  test "a non-numeric parameter without readings plots empty in history" do
    module =
      create_module(["Readable"], [
        {"value", %{"type" => "enum", "members" => %{"off" => 0, "on" => 1}}}
      ])

    assert %{plot_available: false} = PlotDB.module_plot(module, :historical)
  end

  test "a calibratable module without its calibration parameters still plots" do
    module = create_module(["_Calibratable", "Readable"], [{"value", @double}])

    assert %{plottable: true, plot_available: false} = PlotDB.module_plot(module, :historical)
  end
end
