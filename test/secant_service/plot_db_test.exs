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

  describe "envelopes" do
    @array %{"type" => "array", "maxlen" => 10, "members" => %{"type" => "double"}}

    defp envelope(rows),
      do: %{bucket_ms: 60_000, from_ms: 0, until_ms: 600_000, rows: rows}

    test "envelope_params: number lines and numeric arrays of plain plots" do
      param = generate(parameter(name: "temp", datainfo: @double))
      assert [{^param, "line"}] = PlotDB.envelope_params(param)

      array = generate(parameter(name: "spectrum", datainfo: @array))
      assert [{^array, "array"}] = PlotDB.envelope_params(array)

      for class <- ["Readable", "Drivable"] do
        module = create_module([class], [{"value", @double}, {"target", @double}])
        assert [{%{name: "value"}, "line"}] = PlotDB.envelope_params(module)
      end
    end

    test "envelope_params: never a setpoint, an enum, a struct, Calibratable or Acquisition" do
      drivable = create_module(["Drivable"], [{"value", @double}, {"target", @double}])
      target = Enum.find(drivable.parameters, &(&1.name == "target"))
      assert PlotDB.envelope_params(target) == []

      enum = generate(parameter(datainfo: %{"type" => "enum", "members" => %{"a" => 0}}))
      assert PlotDB.envelope_params(enum) == []

      struct =
        generate(
          parameter(datainfo: %{"type" => "struct", "members" => %{"x" => %{"type" => "double"}}})
        )

      assert PlotDB.envelope_params(struct) == []

      for classes <- [["_Calibratable", "Readable"], ["Acquisition", "Readable"]] do
        module = create_module(classes, [{"value", @double}])
        assert PlotDB.envelope_params(module) == []
        refute Map.has_key?(PlotDB.module_plot(module, :historical).option, :_envelope)
      end

      refute Map.has_key?(PlotDB.parameter_plot(target, :historical).option, :_envelope)
    end

    test "a double's first load is marked as an envelope plot" do
      param = generate(parameter(name: "temp", datainfo: @double))
      plot = PlotDB.parameter_plot(param, :historical)

      assert plot.option._envelope == %{kind: "line", on: true, series: [0]}
      # no aggregates in the sandbox: no band rows
      assert plot.option._envelopes == []

      plot =
        PlotDB.put_envelopes(plot, param, :historical, [
          {"value", envelope([[30_000, 1.0, 2.0, 3.0]])}
        ])

      assert [
               %{
                 seriesIndex: 0,
                 bucket_ms: 60_000,
                 from: 0,
                 until: 600_000,
                 rows: [[30_000, 1.0, 2.0, 3.0]]
               }
             ] =
               plot.option._envelopes
    end

    test "a Drivable's envelope is on value, never on target" do
      module = create_module(["Drivable"], [{"value", @double}, {"target", @double}])
      plot = PlotDB.module_plot(module, :historical)
      value_index = Enum.find_index(plot.option.series, &(&1.name == "value"))

      plot =
        PlotDB.put_envelopes(plot, module, :historical, [
          {"value", envelope([[1, 1.0, 1.0, 1.0]])}
        ])

      assert [%{seriesIndex: ^value_index}] = plot.option._envelopes
    end

    test "an array starts without an envelope, and its rows pass through 0-based" do
      array = generate(parameter(name: "spectrum", datainfo: @array))
      plot = PlotDB.parameter_plot(array, :historical)
      assert plot.option._envelope == %{kind: "array", on: false, series: [0]}

      rows = [[30_000, 0, 1.0, 2.0, 3.0], [30_000, 1, 4.0, 5.0, 6.0]]
      plot = PlotDB.put_envelopes(plot, array, :historical, [{"value", envelope(rows)}])
      assert [%{seriesIndex: 0, rows: ^rows}] = plot.option._envelopes
    end

    test "live plots carry no envelope" do
      param = generate(parameter(name: "temp", datainfo: @double))
      refute Map.has_key?(PlotDB.parameter_plot(param, :live).option, :_envelope)
    end

    test "nil points are dropped from envelope array updates only" do
      array = generate(parameter(name: "spectrum", datainfo: @array))
      plot = PlotDB.parameter_plot(array, :historical)
      update = PlotDB.get_trace_updates_batch(plot, [{[1.0, nil, 3.0], 1_000}], array.name)

      # a NaN element (nil) still makes a gap in the live and plain paths
      assert [%{data: [[1_000, 0, 1.0], [1_000, 1, nil], [1_000, 2, 3.0]]}] = update.seriesUpdates

      # dropped only at an envelope's mean-point times
      envelope = envelope([[1_000, 0, 1.0, 1.0, 1.0]])

      assert [%{data: [[1_000, 0, 1.0], [1_000, 2, 3.0]]}] =
               PlotDB.drop_nil_points(update, envelope).seriesUpdates

      assert PlotDB.drop_nil_points(update, envelope([[2_000, 0, 1.0, 1.0, 1.0]])) == update
      assert PlotDB.drop_nil_points(update, nil) == update
    end
  end
end
