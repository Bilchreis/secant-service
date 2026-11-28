defmodule SecantService.PlotDB.TracesTest do
  @moduledoc """
  Resolving a system role's custom plot against a module: what can be drawn
  from the description alone, which elements and labels the traces get from
  the latest readings, and reading numbers and labels out of node values
  without ever raising.
  """
  use SecantService.DataCase, async: true

  alias SecantService.PlotDB.ArrayPlot
  alias SecantService.PlotDB.LabelSource
  alias SecantService.PlotDB.LinesPlot
  alias SecantService.PlotDB.Trace
  alias SecantService.PlotDB.Traces
  alias SecantService.SecNodes
  alias SecantService.SecNodes.Reading.Storage

  @t0 ~U[2026-01-01 00:00:00.000000Z]

  @double %{"type" => "double", "unit" => "A"}
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
  @undeclared %{"type" => "array", "members" => %{"type" => "double"}}

  defp module_with(params) do
    module = generate(sec_module())

    for {name, datainfo} <- params,
        do: generate(parameter(name: name, datainfo: datainfo, module_id: module.id))

    Ash.load!(module, :parameters)
  end

  defp param(module, name), do: Enum.find(module.parameters, &(&1.name == name))

  # readings one second apart, the last one latest
  defp insert(param, values) do
    rows =
      for {value, i} <- Enum.with_index(values),
          do: Storage.to_row(value, param, DateTime.add(@t0, i, :second), %{})

    %Ash.BulkResult{status: :success} = SecNodes.insert_readings(rows)
  end

  defp lines(traces), do: %LinesPlot{traces: traces}

  describe "extract/3" do
    test "reads numbers along struct paths, with atom or string keys" do
      live = %{composition: [10.0, 90.0], total_flow: 2.5}
      stored = %{"composition" => [10.0, 90.0], "total_flow" => 2.5}

      for value <- [live, stored] do
        assert Trace.extract(value, ["total_flow"]) == 2.5
        assert Trace.extract(value, ["composition"], 1) == 90.0
      end

      assert Trace.extract(3.0, []) == 3.0
      assert Trace.extract([1.0, 2.0], [], 0) == 1.0
    end

    test "gives nil instead of raising on anything else" do
      for {value, path, index} <- [
            {%{"composition" => [1.0]}, ["composition"], 3},
            {%{"composition" => [1.0]}, ["missing"], nil},
            {nil, ["a"], nil},
            {"text", [], nil},
            {[1.0, "x"], [], 1},
            {%{"a" => %{"b" => true}}, ["a", "b"], nil},
            {[1.0], [], -1},
            {5, ["a"], 0}
          ] do
        assert Trace.extract(value, path, index) == nil, inspect({value, path, index})
      end
    end
  end

  describe "LabelSource.text/2" do
    test "strings as they are, numbers short, through the template" do
      assert LabelSource.text("N2") == "N2"
      assert LabelSource.text(28.0) == "28"
      assert LabelSource.text(28) == "28"
      assert LabelSource.text(28.5) == "28.5"
      assert LabelSource.text(28.0, "m/z {}") == "m/z 28"
      assert LabelSource.text("<b>N2</b>") == "<b>N2</b>"
    end

    test "nothing usable gives nil" do
      for value <- [nil, "", %{"a" => 1}, [1], true] do
        assert LabelSource.text(value, "m/z {}") == nil, inspect(value)
      end
    end
  end

  describe "drawable?/2" do
    test "number traces, struct fields and elements of short numeric arrays" do
      module = module_with([{"value", @mfc}, {"spectrum", @spectrum}, {"target", @double}])

      assert Traces.drawable?(module, lines([%Trace{param: "target"}]))
      assert Traces.drawable?(module, lines([%Trace{param: "value", path: ["total_flow"]}]))

      assert Traces.drawable?(
               module,
               lines([%Trace{param: "value", path: ["composition"], pick: :each}])
             )

      assert Traces.drawable?(module, lines([%Trace{param: "spectrum", pick: {:index, 3}}]))
    end

    test "nothing else, from the description alone and without raising" do
      enum = %{"type" => "enum", "members" => %{"a" => 0}}
      long = %{"type" => "array", "maxlen" => 350_000, "members" => %{"type" => "double"}}

      of_structs = %{
        "type" => "array",
        "maxlen" => 3,
        "members" => %{"type" => "struct", "members" => %{"x" => @double}}
      }

      malformed = %{"type" => "struct", "members" => [@double]}

      module =
        module_with([
          {"value", @mfc},
          {"mode", enum},
          {"long", long},
          {"structs", of_structs},
          {"bad", malformed}
        ])

      ref = make_ref()
      me = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:secant_service, :repo, :query],
        fn _event, _measurements, _meta, _ -> send(me, {ref, :query}) end,
        nil
      )

      try do
        for trace <- [
              %Trace{param: "missing"},
              %Trace{param: "mode"},
              %Trace{param: "value"},
              %Trace{param: "value", path: ["gas_list"], pick: :each},
              %Trace{param: "value", path: ["composition"]},
              %Trace{param: "long", pick: :each},
              %Trace{param: "structs", path: ["x"]},
              %Trace{param: "bad", path: ["0"]}
            ] do
          refute Traces.drawable?(module, lines([trace])), inspect(trace)
        end

        refute Traces.drawable?(module, %ArrayPlot{})
        refute Traces.drawable?(module, :nonsense)
      after
        :telemetry.detach({__MODULE__, ref})
      end

      refute_received {^ref, :query}
    end
  end

  describe "resolve/2" do
    test "one trace per element: declared, or as long as the latest reading" do
      module = module_with([{"value", @mfc}, {"undeclared", @undeclared}])
      insert(param(module, "undeclared"), [[1.0, 2.0], [1.0, 2.0, 3.0]])

      traces =
        Traces.resolve(
          module,
          lines([
            %Trace{param: "value", path: ["composition"], pick: :each},
            %Trace{param: "undeclared", pick: :each}
          ])
        )

      assert Enum.map(traces, & &1.series) == [
               "value.composition[0]",
               "value.composition[1]",
               "value.composition[2]",
               "value.composition[3]",
               "undeclared[0]",
               "undeclared[1]",
               "undeclared[2]"
             ]

      assert %{unit: "%", index: 2, path: ["composition"]} = Enum.at(traces, 2)
    end

    test "an undeclared array read longer than 100 elements is left out" do
      module = module_with([{"value", @double}, {"undeclared", @undeclared}])
      insert(param(module, "undeclared"), [Enum.map(1..200, &(&1 * 1.0))])

      assert [%{series: "value"}] =
               Traces.resolve(
                 module,
                 lines([%Trace{param: "value"}, %Trace{param: "undeclared", pick: {:index, 3}}])
               )

      assert Traces.resolve(module, lines([%Trace{param: "undeclared", pick: :each}])) ==
               :no_traces
    end

    test "picks an element by its label value, as a number" do
      module = module_with([{"value", @spectrum}, {"_mass", @spectrum}])
      insert(param(module, "_mass"), [[1.0, 2.0, 28.0, 44.0]])
      mass = %LabelSource{param: "_mass", template: "m/z {}"}

      traces =
        Traces.resolve(
          module,
          lines(
            for m <- [28, 44.0, 29],
                do: %Trace{param: "value", pick: {:match, mass, m}, label: mass}
          )
        )

      assert [
               %{series: "value[2]", index: 2, label: "m/z 28"},
               %{series: "value[3]", index: 3, label: "m/z 44"}
             ] = traces
    end

    test "labels from the same value, and their fallback" do
      module = module_with([{"value", @mfc}])

      insert(param(module, "value"), [
        %{
          "composition" => [1.0, 2.0, 3.0, 4.0],
          "gas_list" => ["N2", "H2", "CO"],
          "total_flow" => 1.0
        }
      ])

      traces =
        Traces.resolve(
          module,
          lines([
            %Trace{
              param: "value",
              path: ["composition"],
              pick: :each,
              label: %LabelSource{path: ["gas_list"]}
            },
            %Trace{param: "value", path: ["total_flow"], label: "total", axis: 1}
          ])
        )

      assert Enum.map(traces, & &1.label) == ["N2", "H2", "CO", nil, "total"]
      assert %{unit: "ml/min", axis: 1} = List.last(traces)
    end

    test "duplicates go before the cap of 16 traces" do
      wide = %{"type" => "array", "maxlen" => 20, "members" => %{"type" => "double"}}
      module = module_with([{"value", @double}, {"wide", wide}])

      traces =
        Traces.resolve(
          module,
          lines([
            %Trace{param: "value"},
            %Trace{param: "value"},
            %Trace{param: "wide", pick: :each}
          ])
        )

      assert length(traces) == 16
      assert ["value", "wide[0]" | _] = Enum.map(traces, & &1.series)
      assert List.last(traces).series == "wide[14]"
    end

    test "nothing drawable gives :no_traces" do
      module = module_with([{"value", @double}])
      assert Traces.resolve(module, lines([%Trace{param: "missing"}])) == :no_traces
      assert Traces.resolve(module, lines([])) == :no_traces
    end
  end

  test "latest_value reads values of any type" do
    module = module_with([{"value", @mfc}])
    reading = %{"composition" => [1.0], "gas_list" => ["N2"], "total_flow" => 2.0}
    insert(param(module, "value"), [reading])

    assert Traces.latest_value(param(module, "value")) == reading
    assert Traces.latest_value(nil) == nil
  end
end
