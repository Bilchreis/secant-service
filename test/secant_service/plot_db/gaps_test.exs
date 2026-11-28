defmodule SecantService.PlotDB.GapsTest do
  # inserts readings: hypertable chunk creation deadlocks with other tests
  # inserting readings concurrently
  use SecantService.DataCase, async: false

  alias SecantService.PlotDB
  alias SecantService.PlotDB.Gaps
  alias SecantService.SecNodes
  alias SecantService.SecNodes.Reading.Storage

  @start ~U[2026-11-27 08:00:00.000000Z]

  defp at(s), do: DateTime.add(@start, s, :second)
  defp ms(s), do: DateTime.to_unix(at(s), :millisecond)

  defp span(node, from, to, opts \\ []) do
    alive = Keyword.get(opts, :alive, to)

    SecNodes.record_span!(%{
      id: Ecto.UUID.generate(),
      sec_node_id: node.uuid,
      started_at: at(from),
      alive_until: at(alive),
      ended_at: to && at(to),
      end_reason: to && Keyword.get(opts, :reason, :disconnected)
    })
  end

  describe "gaps/4" do
    # spans as {started, alive, ended} or {started, alive, ended, reason},
    # in seconds from @start
    defp gaps(spans, now, from \\ nil, to \\ nil) do
      spans
      |> Enum.map(fn
        {s, a, e} -> {at(s), at(a), e && at(e), nil}
        {s, a, e, r} -> {at(s), at(a), e && at(e), r}
      end)
      |> Gaps.gaps(ms(now), from && ms(from), to && ms(to))
    end

    test "the time between spans, and after the last one" do
      assert gaps([{0, 3590, 3590}, {4320, 4320, nil}], 4321) == {:spans, [[ms(3590), ms(4320)]]}

      # the session ended
      assert gaps([{0, 100, 100}], 200) == {:spans, [[ms(100), nil]]}
    end

    test "an open span ends now while alive, at its last heartbeat once stale" do
      assert gaps([{0, 100, nil}], 120) == {:spans, []}
      assert gaps([{0, 100, nil}], 700) == {:spans, [[ms(100), nil, "interrupted"]]}
    end

    test "time before the first span is no gap; no spans at all is :no_spans" do
      assert gaps([{100, 200, 200}, {300, 400, nil}], 401, 0, 400) ==
               {:spans, [[ms(200), ms(300)]]}

      assert Gaps.gaps([], 0, nil, nil) == :no_spans
    end

    test "only gaps overlapping the window, whole, also one the window lies inside" do
      spans = [{0, 100, 100}, {200, 300, 300}, {1000, 1000, nil}]

      assert gaps(spans, 1001, 250, 900) == {:spans, [[ms(300), ms(1000)]]}
      assert gaps(spans, 1001, 400, 500) == {:spans, [[ms(300), ms(1000)]]}
      assert gaps(spans, 1001, 0, 150) == {:spans, [[ms(100), ms(200)]]}
    end

    test "a gap carries the reason of the span whose end starts it" do
      assert gaps([{0, 3590, 3590, :interrupted}, {4320, 4320, nil}], 4321) ==
               {:spans, [[ms(3590), ms(4320), "interrupted"]]}

      # as stored: a string
      assert gaps([{0, 100, 100, "disconnected"}], 200) ==
               {:spans, [[ms(100), nil, "disconnected"]]}

      # a stale open span: recording was interrupted
      assert gaps([{0, 100, nil}], 700) == {:spans, [[ms(100), nil, "interrupted"]]}
    end

    test "the reason is the one of the span that ends the covered time" do
      # a short span inside a longer one doesn't take over its reason
      spans = [{0, 1000, 1000, :stopped}, {100, 200, 200, :disconnected}, {1100, 1100, nil}]
      assert gaps(spans, 1101) == {:spans, [[ms(1000), ms(1100), "stopped"]]}
    end
  end

  describe "for_param/3" do
    test "the gaps of the parameter's session" do
      {node, param} = node_with_parameter()
      span(node, 0, 100)
      span(node, 200, 300)

      span(node, 400, 500, reason: :deactivated)

      assert {:spans,
              [[g0, g1, "disconnected"], [g2, _, "disconnected"], [_, nil, "deactivated"]]} =
               Gaps.for_param(param.id, nil, nil)

      assert {g0, g1, g2} == {ms(100), ms(200), ms(300)}

      # another session's spans don't count
      {_other, other_param} = node_with_parameter()
      assert Gaps.for_param(other_param.id, nil, nil) == :no_spans
    end
  end

  describe "pollinterval_ms/1" do
    test "the last poll interval of the module, in ms" do
      {_node, value} = node_with_parameter()
      poll = generate(parameter(module_id: value.module_id, name: "pollinterval"))

      assert Gaps.pollinterval_ms(value.id) == nil

      rows =
        for {seconds, i} <- Enum.with_index([5.0, 2.0]),
            do: Storage.to_row(seconds, poll, at(i), %{})

      %Ash.BulkResult{status: :success} = SecNodes.insert_readings(rows)

      assert Gaps.pollinterval_ms(value.id) == 2_000
    end
  end

  describe "the plots" do
    test "a number plot carries its session's gaps; an enum plot carries none" do
      {node, value} = node_with_parameter()
      span(node, 0, 100)
      span(node, 200, 200, alive: 200)

      plot = PlotDB.init(value, :historical)

      assert %{gaps: [[g0, g1, "disconnected"], [_, nil, "disconnected"]], fallback: %{}} =
               plot.option._gaps

      assert {g0, g1} == {ms(100), ms(200)}

      {enum_node, enum} =
        node_with_parameter(datainfo: %{"type" => "enum", "members" => %{"a" => 0, "b" => 1}})

      span(enum_node, 0, 100)
      refute Map.has_key?(PlotDB.init(enum, :historical).option, :_gaps)
    end

    test "a session without spans lists its value lines for the fallback" do
      module = generate(sec_module(interface_classes: ["Drivable"]))
      value = generate(parameter(module_id: module.id, name: "value"))
      _target = generate(parameter(module_id: module.id, name: "target"))
      poll = generate(parameter(module_id: module.id, name: "pollinterval"))

      %Ash.BulkResult{status: :success} =
        SecNodes.insert_readings([Storage.to_row(2.0, poll, at(0), %{})])

      _ = value
      module = Ash.load!(module, :parameters)

      plot = PlotDB.init(module, :historical)
      index = Enum.find_index(plot.option.series, &(&1.name == "value"))

      assert plot.option._gaps == %{gaps: [], fallback: %{index => 2_000}}

      # live plots get no fallback
      assert PlotDB.init(module, :live).option._gaps == %{gaps: [], fallback: %{}}
    end

    @array %{"type" => "array", "maxlen" => 10, "members" => %{"type" => "double"}}

    defp insert_arrays(param, arrays) do
      rows =
        for {array, i} <- Enum.with_index(arrays), do: Storage.to_row(array, param, at(i), %{})

      %Ash.BulkResult{status: :success} = SecNodes.insert_readings(rows)
    end

    test "a numeric array plot carries its session's gaps, and no fallback" do
      {node, value} = node_with_parameter(datainfo: @array)
      insert_arrays(value, [[1.0, 2.0], [3.0, 4.0]])
      span(node, 0, 100)
      span(node, 200, 200, alive: 200)

      plot = PlotDB.init(value, :historical)
      assert plot.plot_type == :array_heatmap
      assert %{gaps: [[g0, g1 | _], [_, nil | _]], fallback: %{}} = plot.option._gaps
      assert {g0, g1} == {ms(100), ms(200)}
    end

    test "an array of a session without spans gets no fallback, even with a poll interval" do
      module = generate(sec_module())
      value = generate(parameter(module_id: module.id, name: "value", datainfo: @array))
      poll = generate(parameter(module_id: module.id, name: "pollinterval"))
      insert_arrays(value, [[1.0, 2.0]])

      %Ash.BulkResult{status: :success} =
        SecNodes.insert_readings([Storage.to_row(2.0, poll, at(0), %{})])

      assert PlotDB.init(value, :historical).option._gaps == %{gaps: [], fallback: %{}}
    end

    test "a setpoint array and a long array drawn as its latest reading carry none" do
      {node, target} = node_with_parameter(name: "target", datainfo: @array)
      insert_arrays(target, [[1.0, 2.0]])
      span(node, 0, 100)
      refute Map.has_key?(PlotDB.init(target, :historical).option, :_gaps)

      {long_node, long} = node_with_parameter(datainfo: %{@array | "maxlen" => 1000})
      insert_arrays(long, [Enum.map(1..200, &(&1 * 1.0))])
      span(long_node, 0, 100)
      plot = PlotDB.init(long, :historical)
      refute plot[:plot_type] == :array_heatmap
      refute Map.has_key?(plot.option, :_gaps)
    end
  end
end
