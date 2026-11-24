defmodule SecantService.PlotDB.DTypesTest do
  @moduledoc """
  Which SECoP datatypes get a plot, and how readings become chart points for
  each of them. Pure functions: no database, no node.
  """
  use ExUnit.Case, async: true

  alias SecantService.PlotDB.DTypePlot
  alias SecantService.PlotDB.DTypes.{ArrayHeatmap, ArrayLatest, Scalar, Struct}
  alias SecantService.PlotDB.DTypes.Enum, as: EnumDType

  @double %{"type" => "double", "unit" => "K"}
  @enum %{"type" => "enum", "members" => %{"off" => 0, "on" => 1}}

  describe "for_datainfo/1" do
    test "numbers plot as lines" do
      for type <- ["double", "int", "scaled"] do
        assert DTypePlot.for_datainfo(%{"type" => type}) == Scalar
      end
    end

    test "an enum plots as state bands" do
      assert DTypePlot.for_datainfo(@enum) == EnumDType
    end

    test "a numeric array plots as a heatmap, other arrays do not plot" do
      for member <- ["double", "int", "scaled"] do
        datainfo = %{"type" => "array", "members" => %{"type" => member}}
        assert DTypePlot.for_datainfo(datainfo) == ArrayHeatmap
      end

      refute DTypePlot.for_datainfo(%{"type" => "array", "members" => %{"type" => "string"}})
    end

    test "a struct plots if one of its members does" do
      plottable = %{
        "type" => "struct",
        "members" => %{"name" => %{"type" => "string"}, "t" => @double}
      }

      assert DTypePlot.for_datainfo(plottable) == Struct

      text_only = %{"type" => "struct", "members" => %{"name" => %{"type" => "string"}}}
      refute DTypePlot.for_datainfo(text_only)
    end

    test "types without a numeric reading do not plot" do
      for type <- ["string", "bool", "blob", "tuple", "command"] do
        refute DTypePlot.for_datainfo(%{"type" => type}), type
      end

      refute DTypePlot.for_datainfo(nil)
    end
  end

  describe "Scalar" do
    test "points are [timestamp, value] in arrival order" do
      [series] = Scalar.build_series("value", [1, 2], [0.5, 1.5], @double)
      assert series.data == [[1, 0.5], [2, 1.5]]
    end

    test "live updates go to the series of that parameter" do
      option = %{series: [%{name: "value"}, %{name: "target"}]}

      assert [%{seriesIndex: 1, data: [[10, 4.0], [11, 5.0]]}] =
               Scalar.series_updates(option, [{4.0, 10}, {5.0, 11}], "target")
    end
  end

  describe "Enum" do
    test "a point names the state and keeps its number" do
      [series] = EnumDType.build_series("status", [1, 2], [1, 0], @enum)
      assert [%{name: "on (1)", value: [1, 0]}, %{name: "off (0)", value: [2, 0]}] = series.data
    end

    test "live updates name known states and fall back to the number" do
      option = %{
        series: [%{name: "status"}],
        _enumMembers: EnumDType.enum_int_to_info(@enum["members"])
      }

      assert [
               %{
                 seriesIndex: 0,
                 data: [%{name: "on (1)"}, %{name: "7 (7)", itemStyle: %{color: "#888888"}}]
               }
             ] =
               EnumDType.series_updates(option, [{1, 10}, {7, 11}], "status")
    end
  end

  describe "ArrayHeatmap" do
    test "each element becomes a [timestamp, index, value] point" do
      [series] = ArrayHeatmap.build_series("spectrum", [1, 2], [[1.0, 2.0], [3.0]], %{})
      assert series.data == [[1, 0, 1.0], [1, 1, 2.0], [2, 0, 3.0]]

      assert [%{seriesIndex: 0, data: [[5, 0, 7.0], [5, 1, 8.0]]}] =
               ArrayHeatmap.series_updates(%{}, [{[7.0, 8.0], 5}], "spectrum")
    end

    test "the index axis fits the longest reading" do
      assert ArrayHeatmap.max_len([[1], [1, 2, 3], nil, [1, 2]]) == 3
      assert ArrayHeatmap.array_len_from_datapoints([{[1, 2], 1}, {[1], 2}]) == 2
    end

    test "the unit comes from the members when the array has none" do
      assert ArrayHeatmap.unit(%{"members" => %{"unit" => "nm"}}) == "nm"
      assert ArrayHeatmap.unit(%{"unit" => "V", "members" => %{"unit" => "nm"}}) == "V"
    end
  end

  describe "ArrayLatest.points/1" do
    test "a short array keeps every number and skips the rest" do
      assert ArrayLatest.points([1.0, nil, 3.0]) == [[0, 1.0], [2, 3.0]]
    end

    test "a long array keeps each chunk's minimum and maximum" do
      arr = for i <- 0..9_999, do: if(i == 4_321, do: 1.0e6, else: 0.0)
      points = ArrayLatest.points(arr)

      assert length(points) <= 4_000
      assert [4_321, 1.0e6] in points
      assert points == Enum.sort_by(points, &hd/1)
    end
  end

  describe "Struct" do
    @struct %{
      "type" => "struct",
      "members" => %{"t" => @double, "mode" => @enum, "note" => %{"type" => "string"}}
    }

    test "each plottable member gets its own series, named after the member" do
      names =
        Struct.build_series("p", [1], [%{"t" => 1.0, "mode" => 1, "note" => "x"}], @struct)
        |> Enum.map(& &1.name)

      assert Enum.sort(names) == ["p.mode", "p.t"]
    end

    test "live updates split a reading into its members, with string or atom keys" do
      plot = Struct.build_struct_option("p", [], [], @struct, :live)

      updates =
        Struct.series_updates(
          plot,
          [{%{"t" => 1.0, "mode" => 1}, 10}, {%{t: 2.0, mode: 0}, 11}],
          "p"
        )

      t_index = Enum.find_index(plot.series, &(&1.name == "p.t"))
      assert %{data: [[10, 1.0], [11, 2.0]]} = Enum.find(updates, &(&1.seriesIndex == t_index))
    end
  end

  describe "Struct with array fields" do
    @mfc %{
      "type" => "struct",
      "members" => %{
        "flow" => @double,
        "mix" => %{"type" => "array", "maxlen" => 2, "members" => %{"type" => "double"}}
      }
    }

    defp mfc_option do
      Struct.build_struct_option(
        "value",
        [1, 2],
        [%{"flow" => 1.0, "mix" => [30.0, 70.0]}, %{"flow" => 2.0, "mix" => [40.0, 60.0]}],
        @mfc,
        :historical,
        target: {[1], [%{"flow" => 0.0, "mix" => [100.0, 0.0]}]}
      )
    end

    test "value and target of an array share each heatmap cell, value on top" do
      option = mfc_option()

      assert [value, target] = Enum.filter(option.series, & &1[:_arrayHeat])
      assert %{name: "value.mix", _heatHalf: "upper", _arrayLen: 2} = value
      assert %{name: "target.mix", _heatHalf: "lower", _targetArray: true} = target
      assert value.yAxisIndex == target.yAxisIndex
    end

    test "the colour scale spans the values of value and target" do
      assert [%{min: +0.0, max: 100.0}] = mfc_option().visualMap
    end

    test "updates of the target's array go to the target heatmap" do
      option = mfc_option()
      target_idx = Enum.find_index(option.series, &(&1[:name] == "target.mix"))
      value_idx = Enum.find_index(option.series, &(&1[:name] == "value.mix"))

      assert [%{seriesIndex: ^target_idx, data: [[5, 0, 1.0], [5, 1, 2.0]]}] =
               option
               |> Struct.series_updates([{%{"mix" => [1.0, 2.0]}, 5}], "target")
               |> Enum.filter(&(&1.seriesIndex in [target_idx, value_idx]))
    end
  end

  describe "historical plots" do
    @array %{"type" => "array", "maxlen" => 2, "members" => %{"type" => "double"}}

    defp historical_options do
      %{
        scalar: Scalar.timeseries_option([], "K", :historical),
        enum: EnumDType.enum_timeseries_option([], @enum["members"], "value", :historical),
        array: ArrayHeatmap.heatmap_option([], 2, nil, :historical),
        struct:
          Struct.build_struct_option(
            "p",
            [],
            [],
            %{"type" => "struct", "members" => %{"t" => @double, "a" => @array}},
            :historical
          )
      }
    end

    test "every type zooms and asks for the readings of the zoomed window" do
      for {type, option} <- historical_options() do
        assert %{aggregated: false, bucket_ms: nil} = option[:_windowFetch], "#{type}"
        assert [%{type: "inside"}] = option.dataZoom, "#{type}"
        assert %{feature: %{dataZoom: _, restore: _}} = option.toolbox, "#{type}"
      end
    end

    test "a struct zooms all its time axes together" do
      %{struct: option} = historical_options()

      assert [%{xAxisIndex: [0, 1]}] = option.dataZoom
      assert option.toolbox.feature.dataZoom.xAxisIndex == [0, 1]
    end

    test "plots of held values keep the readings outside the zoomed window" do
      options = historical_options()

      for type <- [:enum, :array, :struct] do
        assert [%{filterMode: "none"}] = options[type].dataZoom, "#{type}"
      end

      assert [%{filterMode: "filter"}] = options.scalar.dataZoom
    end

    test "live plots do not fetch windows" do
      refute Map.has_key?(ArrayHeatmap.heatmap_option([], 2, nil, :live), :_windowFetch)

      refute Map.has_key?(
               EnumDType.enum_timeseries_option([], @enum["members"], "v", :live),
               :dataZoom
             )
    end
  end
end
