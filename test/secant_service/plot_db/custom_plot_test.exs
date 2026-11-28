defmodule SecantService.PlotDB.CustomPlotTest do
  @moduledoc """
  Building a system role's custom module plot from stored readings: a lines
  plot of traces into parameters, struct fields and array elements, and an
  array plot with labelled indexes.
  """
  # inserts readings: hypertable chunk creation deadlocks with other tests
  # inserting readings concurrently
  use SecantService.DataCase, async: false

  alias SecantService.PlotDB
  alias SecantService.PlotDB.ArrayPlot
  alias SecantService.PlotDB.LabelSource
  alias SecantService.PlotDB.LinesPlot
  alias SecantService.PlotDB.Trace
  alias SecantService.SecNodes
  alias SecantService.SecNodes.Reading.Storage

  @start ~U[2026-11-27 08:00:00.000000Z]

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

  @mfc_plot %LinesPlot{
    traces: [
      %Trace{
        param: "value",
        path: ["composition"],
        pick: :each,
        label: %LabelSource{path: ["gas_list"]}
      },
      %Trace{param: "value", path: ["total_flow"], axis: 1}
    ]
  }

  defp at(s), do: DateTime.add(@start, s, :second)
  defp ms(s), do: DateTime.to_unix(at(s), :millisecond)

  defp module_with(params) do
    node = generate(sec_node())
    module = generate(sec_module(sec_node_id: node.uuid, interface_classes: ["Readable"]))

    for {name, datainfo} <- params,
        do: generate(parameter(name: name, datainfo: datainfo, module_id: module.id))

    {node, Ash.load!(module, :parameters)}
  end

  defp param(module, name), do: Enum.find(module.parameters, &(&1.name == name))

  # readings one second apart from @start
  defp insert(param, values) do
    rows =
      for {value, i} <- Enum.with_index(values),
          do: Storage.to_row(value, param, at(i), %{})

    %Ash.BulkResult{status: :success} = SecNodes.insert_readings(rows)
  end

  defp mfc(composition, gases),
    do: %{"composition" => composition, "gas_list" => gases, "total_flow" => 2.0}

  defp series(plot), do: Enum.map(plot.option.series, & &1.name)

  # a historical plot pins its first reading to where it starts: compare values
  defp values(series), do: Enum.map(series.data, &List.last/1)

  defp count_queries(fun) do
    ref = make_ref()
    me = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:secant_service, :repo, :query],
      fn _event, _measurements, _meta, _ -> send(me, {ref, :query}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach({__MODULE__, ref})
    end

    count = fn count -> receive(do: ({^ref, :query} -> count.(count) + 1), after: (0 -> 0)) end
    count.(count)
  end

  describe "lines plot" do
    test "the MFC group: gas-labelled composition and total flow on a second axis" do
      {_node, module} = module_with([{"value", @mfc}])

      insert(param(module, "value"), [
        mfc([10.0, 20.0, 30.0, 40.0], ["N2", "H2", "CO", "O2"]),
        mfc([15.0, 15.0, 30.0, 40.0], ["N2", "H2", "CO", "O2"])
      ])

      plot = PlotDB.init(module, :historical, @mfc_plot)

      assert series(plot) == [
               "value.composition[0]",
               "value.composition[1]",
               "value.composition[2]",
               "value.composition[3]",
               "value.total_flow"
             ]

      assert Enum.map(plot.option.series, &Map.get(&1, :_label)) == ["N2", "H2", "CO", "O2", nil]

      [composition | _] = plot.option.series
      assert values(composition) == [10.0, 15.0]
      refute Map.has_key?(composition, :yAxisIndex)
      assert %{yAxisIndex: 1, data: [[_, 2.0], [_, 2.0]]} = List.last(plot.option.series)

      assert [%{name: "%"}, %{name: "ml/min", position: "right"}] = plot.option.yAxis
      assert Map.keys(plot.traces) == ["value"]
      assert [%{series: "value"}] = plot.resolved
    end

    test "equal labels still give a series each, and a missing label falls back" do
      {_node, module} = module_with([{"value", @mfc}])
      insert(param(module, "value"), [mfc([1.0, 2.0, 3.0, 4.0], ["N2", "N2", "CO"])])

      plot = PlotDB.init(module, :historical, @mfc_plot)

      assert length(plot.option.series) == 5
      assert Enum.map(plot.option.series, &Map.get(&1, :_label)) == ["N2", "N2", "CO", nil, nil]
    end

    test "costs a window per parameter, not per trace" do
      {_node, module} = module_with([{"value", @mfc}])
      insert(param(module, "value"), [mfc([1.0, 2.0, 3.0, 4.0], ["N2", "H2", "CO", "O2"])])

      one = %LinesPlot{
        traces: [%Trace{param: "value", path: ["composition"], pick: {:index, 0}}]
      }

      four = %LinesPlot{
        traces: [%Trace{param: "value", path: ["composition"], pick: :each}]
      }

      one_count = count_queries(fn -> PlotDB.init(module, :historical, one) end)
      four_count = count_queries(fn -> PlotDB.init(module, :historical, four) end)

      assert four_count == one_count
    end

    test "picks the spectrum elements of given masses, labelled by mass" do
      {_node, module} = module_with([{"value", @spectrum}, {"_mass", @spectrum}])
      insert(param(module, "_mass"), [[1.0, 2.0, 28.0, 44.0]])
      insert(param(module, "value"), [[0.1, 0.2, 0.3, 0.4], [0.5, 0.6, 0.7, 0.8]])
      mass = %LabelSource{param: "_mass", template: "m/z {}"}

      spec = %LinesPlot{
        traces:
          for(m <- [28, 44], do: %Trace{param: "value", pick: {:match, mass, m}, label: mass})
      }

      plot = PlotDB.init(module, :historical, spec)

      assert series(plot) == ["value[2]", "value[3]"]
      assert Enum.map(plot.option.series, & &1._label) == ["m/z 28", "m/z 44"]
      assert values(hd(plot.option.series)) == [0.3, 0.7]
    end

    test "a reading with no number at a trace's path gives no point" do
      {_node, module} = module_with([{"value", @mfc}])

      insert(param(module, "value"), [
        mfc([1.0, 2.0, 3.0, 4.0], []),
        %{"total_flow" => 3.0},
        mfc([5.0, 6.0, 7.0], [])
      ])

      plot = PlotDB.init(module, :historical, @mfc_plot)
      by_name = Map.new(plot.option.series, &{&1.name, values(&1)})

      assert by_name["value.composition[0]"] == [1.0, 5.0]
      assert by_name["value.composition[3]"] == [4.0]
      assert by_name["value.total_flow"] == [2.0, 3.0, 2.0]
    end

    test "setpoints are held, hidden traces start deselected" do
      {_node, module} = module_with([{"value", @double}, {"target", @double}, {"limit", @double}])
      insert(param(module, "value"), [1.0, 2.0])

      spec = %LinesPlot{
        traces: [
          %Trace{param: "value"},
          %Trace{param: "target", setpoint?: true},
          %Trace{param: "limit", hidden?: true}
        ]
      }

      plot = PlotDB.init(module, :live, spec)

      assert %{_held: true, _target: true} = Enum.at(plot.option.series, 1)
      assert plot.option.legend.selected == %{"limit" => false}
      assert [%{setpoint?: false}, %{series: "target", setpoint?: true}, _] = plot.resolved
    end

    test "live readings fan out to their traces by stable name" do
      {_node, module} = module_with([{"value", @mfc}])
      plot = PlotDB.init(module, :live, @mfc_plot)

      # live struct readings have atom keys; another gas list keeps the labels
      update =
        PlotDB.trace_updates(
          plot,
          [{%{composition: [1.0, 2.0, 3.0, 4.0], gas_list: ["Ar"], total_flow: 9.0}, 1000}],
          "value"
        )

      assert %{seriesUpdates: updates} = update
      assert Enum.map(updates, & &1.seriesIndex) == [0, 1, 2, 3, 4]
      assert List.last(updates).data == [[1000, 9.0]]
      assert PlotDB.trace_updates(plot, [{1.0, 1000}], "other") == %{seriesUpdates: []}
      assert PlotDB.drawn_params(plot, module) == ["value"]
    end

    test "a whole number parameter gets a band, an element trace doesn't" do
      {_node, module} = module_with([{"value", @spectrum}, {"pressure", @double}])
      insert(param(module, "pressure"), [1.0, 2.0])
      insert(param(module, "value"), [[1.0, 2.0]])

      spec = %LinesPlot{
        traces: [%Trace{param: "pressure"}, %Trace{param: "value", pick: {:index, 0}}]
      }

      plot = PlotDB.init(module, :historical, spec)
      assert plot.option._envelope.series == [0]
    end

    test "recording gaps; a session without spans estimates them for the whole value only" do
      {node, module} =
        module_with([{"value", @double}, {"spectrum", @spectrum}, {"pollinterval", @double}])

      insert(param(module, "value"), [1.0, 2.0])
      insert(param(module, "pollinterval"), [2.0])

      spec = %LinesPlot{
        traces: [%Trace{param: "value"}, %Trace{param: "spectrum", pick: {:index, 2}}]
      }

      plot = PlotDB.init(module, :historical, spec)
      assert plot.option._gaps == %{gaps: [], fallback: %{0 => 2_000}}

      SecNodes.record_span!(%{
        id: Ecto.UUID.generate(),
        sec_node_id: node.uuid,
        started_at: at(0),
        alive_until: at(10),
        ended_at: at(10),
        end_reason: :disconnected
      })

      plot = PlotDB.init(module, :historical, spec)
      assert %{gaps: [[g0, nil | _]]} = plot.option._gaps
      assert g0 == ms(10)
    end

    test "nothing resolved falls back to the generic plot" do
      {_node, module} = module_with([{"value", @double}])
      spec = %LinesPlot{traces: [%Trace{param: "missing"}]}

      assert PlotDB.init(module, :historical, spec) == PlotDB.init(module, :historical)
    end
  end

  test "a generic struct plot's live update still lands on its own series" do
    struct = %{"type" => "struct", "members" => %{"x" => @double, "y" => @double}}
    {_node, module} = module_with([{"value", struct}])
    plot = PlotDB.init(module, :live)

    %{seriesUpdates: updates} = PlotDB.trace_updates(plot, [{%{"y" => 5.0}, 1000}], "value")
    y_index = Enum.find_index(plot.option.series, &(&1.name == "value.y"))

    assert Enum.any?(updates, &(&1.seriesIndex == y_index and &1.data == [[1000, 5.0]]))

    refute Enum.any?(
             updates,
             &(&1.seriesIndex == 0 and &1.data == [[1000, 5.0]] and y_index != 0)
           )
  end

  describe "array plot" do
    @mass_plot %ArrayPlot{
      labels: %LabelSource{param: "_mass", template: "m/z {}"},
      axis_name: "m/z"
    }

    test "labels the heatmap's index from the label source" do
      {_node, module} = module_with([{"value", @spectrum}, {"_mass", @spectrum}])
      insert(param(module, "value"), [[0.1, 0.2, 0.3]])
      insert(param(module, "_mass"), [Enum.map(1..10, &(&1 * 1.0))])

      plot = PlotDB.init(module, :historical, @mass_plot)

      assert plot.plot_type == :array_heatmap
      # all ten: rows added as the array grows keep their labels
      assert plot.option._indexLabels == Enum.map(1..10, &"m/z #{&1}")
      assert plot.option.yAxis.name == "m/z"
    end

    test "fewer labels than elements label what they cover" do
      {_node, module} = module_with([{"value", @spectrum}, {"_mass", @spectrum}])
      insert(param(module, "value"), [Enum.map(1..100, &(&1 * 1.0))])
      insert(param(module, "_mass"), [Enum.map(1..90, &(&1 * 1.0))])

      plot = PlotDB.init(module, :historical, @mass_plot)
      assert length(plot.option._indexLabels) == 90
    end

    test "a latest-reading plot is labelled only up to 4000 entries" do
      long = %{"type" => "array", "maxlen" => 20_000, "members" => %{"type" => "double"}}
      {_node, module} = module_with([{"value", long}, {"_mass", long}])
      insert(param(module, "value"), [Enum.map(1..3000, &(&1 * 1.0))])
      insert(param(module, "_mass"), [Enum.map(1..3000, &(&1 * 1.0))])

      plot = PlotDB.init(module, :historical, @mass_plot)
      assert plot.plot_type == :array_latest
      assert length(plot.option._indexLabels) == 3000
      assert plot.option.xAxis.name == "m/z"

      insert(param(module, "_mass"), [Enum.map(1..10_000, &(&1 * 1.0))])
      plot = PlotDB.init(module, :historical, @mass_plot)
      refute Map.has_key?(plot.option, :_indexLabels)
    end

    test "a rebuilt latest-reading plot reads its labels again" do
      {_node, module} = module_with([{"value", @spectrum}, {"_mass", @spectrum}])
      insert(param(module, "_mass"), [[1.0, 2.0]])

      rebuilt =
        param(module, "value")
        |> PlotDB.DTypes.ArrayLatest.plot({[0.5, 0.6], 1000})
        |> PlotDB.put_index_labels(module, @mass_plot)

      assert rebuilt.option._indexLabels == ["m/z 1", "m/z 2"]
    end
  end
end
