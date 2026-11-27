defmodule SecantService.PlotDBTest do
  @moduledoc """
  Plots are built from the database only. A session without readings plots
  empty; nothing is read from the device at that address.
  """
  use SecantService.DataCase, async: false

  alias SecantService.PlotDB
  alias SecantService.PlotDB.Bands

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
  @array %{"type" => "array", "maxlen" => 10, "members" => %{"type" => "double"}}

  test "a readable without readings plots empty in history" do
    module = create_module(["Readable"], [{"value", @double}])

    assert %{plottable: true, option: %{series: [%{data: []}]}} =
             PlotDB.module_plot(module, :historical)
  end

  test "a non-numeric parameter without readings plots empty in history" do
    module =
      create_module(["Readable"], [
        {"value", %{"type" => "enum", "members" => %{"off" => 0, "on" => 1}}}
      ])

    assert %{plottable: true, option: %{series: [%{data: []} | _]}} =
             PlotDB.module_plot(module, :historical)
  end

  test "a calibratable module without its calibration parameters still plots" do
    module = create_module(["_Calibratable", "Readable"], [{"value", @double}])

    assert %{plottable: true, option: %{series: [%{name: "value"}]}} =
             PlotDB.module_plot(module, :historical)
  end

  describe "lines" do
    test "a parameter on its own is the plot's value; a setpoint is held" do
      param = generate(parameter(name: "temp", datainfo: @double))
      assert [%{param: ^param, series: "value", setpoint?: false}] = PlotDB.lines(param)

      target = generate(parameter(name: "target", datainfo: @double))
      assert [%{series: "value", setpoint?: true}] = PlotDB.lines(target)
    end

    test "a module's lines follow its interface class, as far as it has them" do
      drivable = create_module(["Drivable"], [{"value", @double}, {"target", @double}])

      assert [%{series: "value", setpoint?: false}, %{series: "target", setpoint?: true}] =
               PlotDB.lines(drivable)

      calibratable =
        create_module(["_Calibratable", "Readable"], [
          {"value", @double},
          {"_target_calibrated", @double}
        ])

      assert [
               %{series: "value"},
               %{series: "_target_calibrated", setpoint?: true, hidden?: true}
             ] = PlotDB.lines(calibratable)

      assert PlotDB.lines(create_module(["Drivable"], [{"target", @double}])) == []
    end

    test "a calibratable's lines are numbers only" do
      enum = %{"type" => "enum", "members" => %{"a" => 0}}
      assert PlotDB.lines(create_module(["_Calibratable", "Readable"], [{"value", enum}])) == []
    end
  end

  describe "updates" do
    @struct %{"type" => "struct", "members" => %{"x" => @double}}

    test "a struct parameter on its own takes live readings under its own name" do
      param = generate(parameter(name: "settings", datainfo: @struct))
      plot = PlotDB.parameter_plot(param, :live)

      assert %{seriesUpdates: [%{data: [[10, 1.0]]}]} =
               PlotDB.trace_updates(plot, [{%{"x" => 1.0}, 10}], "settings")
    end

    test "readings of a parameter the plot doesn't draw update nothing" do
      param = generate(parameter(name: "temp", datainfo: @double))
      plot = PlotDB.parameter_plot(param, :live)
      assert PlotDB.trace_updates(plot, [{1.0, 10}], "other") == %{seriesUpdates: []}
    end

    test "a Drivable's setpoint goes to the target series" do
      module = create_module(["Drivable"], [{"value", @double}, {"target", @double}])
      plot = PlotDB.module_plot(module, :live)
      target_index = Enum.find_index(plot.option.series, &(&1.name == "target"))

      assert %{seriesUpdates: [%{seriesIndex: ^target_index}]} =
               PlotDB.trace_updates(plot, [{1.0, 10}], "target")
    end

    test "_target_calibrated is drawn as a setpoint" do
      module =
        create_module(["_Calibratable", "Readable"], [
          {"value", @double},
          {"_target_calibrated", @double}
        ])

      plot = PlotDB.module_plot(module, :live)
      assert %{_target: true} = Enum.find(plot.option.series, &(&1.name == "_target_calibrated"))
    end

    test "a heatmap outgrows when a reading is longer than it carries" do
      array = generate(parameter(name: "spectrum", datainfo: @array))
      plot = PlotDB.parameter_plot(array, :live)
      long = List.duplicate(1.0, 101)

      assert PlotDB.outgrown(plot, "spectrum", [{[1.0], 1}]) == nil
      assert PlotDB.outgrown(plot, "spectrum", [{long, 1}, {[1.0], 2}]) == {[1.0], 2}
      assert PlotDB.outgrown(plot, "other", [{long, 1}]) == nil
    end
  end

  describe "bands" do
    defp envelope(rows),
      do: %{bucket_ms: 60_000, from_ms: 0, until_ms: 600_000, rows: rows}

    defp band_lines(secop_obj),
      do: secop_obj |> PlotDB.lines() |> Enum.filter(&Bands.eligible?/1) |> Enum.map(& &1.series)

    test "number lines carry a band; setpoints, enums, structs and arrays don't" do
      assert band_lines(generate(parameter(name: "temp", datainfo: @double))) == ["value"]

      drivable = create_module(["Drivable"], [{"value", @double}, {"target", @double}])
      assert band_lines(drivable) == ["value"]
      target = Enum.find(drivable.parameters, &(&1.name == "target"))
      assert band_lines(target) == []

      for datainfo <- [%{"type" => "enum", "members" => %{"a" => 0}}, @struct, @array] do
        assert band_lines(generate(parameter(datainfo: datainfo))) == [], inspect(datainfo)
        plot = PlotDB.parameter_plot(generate(parameter(datainfo: datainfo)), :historical)
        refute Map.has_key?(plot.option, :_envelope)
      end
    end

    test "a double's first load is marked as a band plot" do
      param = generate(parameter(name: "temp", datainfo: @double))
      plot = PlotDB.parameter_plot(param, :historical)

      assert plot.option._envelope == %{on: true, series: [0]}
      # no aggregates in the sandbox: no band rows
      assert plot.option._envelopes == []

      assert %{seriesIndex: 0, bucket_ms: 60_000, from: 0, until: 600_000, rows: [[1, 2, 3, 4]]} =
               Bands.payload(plot.option, "value", envelope([[1, 2, 3, 4]]))
    end

    test "a band goes to its own line or to none, never to another line" do
      module = create_module(["Drivable"], [{"value", @double}, {"target", @double}])
      plot = PlotDB.module_plot(module, :historical)
      value_index = Enum.find_index(plot.option.series, &(&1.name == "value"))

      assert plot.option._envelope.series == [value_index]
      assert Bands.payload(plot.option, "nope", envelope([[1, 1.0, 1.0, 1.0]])) == nil
    end

    test "a Calibratable's bands are on value and _value_uncalibrated" do
      module =
        create_module(["_Calibratable", "Readable"], [
          {"value", @double},
          {"target", @double},
          {"_value_uncalibrated", @double},
          {"_target_calibrated", @double}
        ])

      assert band_lines(module) == ["value", "_value_uncalibrated"]

      plot = PlotDB.module_plot(module, :historical)
      index = fn name -> Enum.find_index(plot.option.series, &(&1.name == name)) end
      assert plot.option._envelope.series == [index.("value"), index.("_value_uncalibrated")]
    end

    test "live plots carry no band" do
      param = generate(parameter(name: "temp", datainfo: @double))
      refute Map.has_key?(PlotDB.parameter_plot(param, :live).option, :_envelope)
    end
  end
end
