defmodule SecantServiceWeb.ValueFormatTest do
  use ExUnit.Case, async: true

  alias SecantServiceWeb.ValueFormat
  alias SecantService.Util

  describe "short/2" do
    test "numbers carry their unit" do
      assert ValueFormat.short(12.5, %{"type" => "double", "unit" => "mln/min"}) == "12.5 mln/min"
      assert ValueFormat.short(3, %{"type" => "int"}) == "3"
    end

    test "enums show the member name" do
      datainfo = %{"type" => "enum", "members" => %{"closed" => 0, "open" => 1}}
      assert ValueFormat.short(1, datainfo) == "open"
      assert ValueFormat.short(7, datainfo) == "7"
    end

    test "structs read atom or string keys" do
      datainfo = %{
        "type" => "struct",
        "members" => %{"flow" => %{"type" => "double", "unit" => "ml/min"}}
      }

      assert ValueFormat.short(%{flow: 2.0}, datainfo) == "{flow: 2.0 ml/min}"
      assert ValueFormat.short(%{"flow" => 2.0}, datainfo) == "{flow: 2.0 ml/min}"
    end

    test "long arrays are summarised" do
      datainfo = %{"type" => "array", "members" => %{"type" => "double"}}

      assert ValueFormat.short(Enum.to_list(1..100) |> Enum.map(&(&1 * 1.0)), datainfo) ==
               "array · 100 items"
    end

    test "nil is a dash" do
      assert ValueFormat.short(nil, %{"type" => "double"}) == "—"
    end
  end

  test "limits/1 describes the allowed range" do
    assert ValueFormat.limits(%{"type" => "double", "min" => 0.0, "max" => 200.0}) ==
             "0.0 … 200.0"

    assert ValueFormat.limits(%{"type" => "double", "min" => 0.0}) == "≥ 0.0"
    assert ValueFormat.limits(%{"type" => "string"}) == nil
  end

  test "type_label/1 names nested types" do
    assert ValueFormat.type_label(%{"type" => "array", "members" => %{"type" => "double"}}) ==
             "array<double>"

    assert ValueFormat.type_label(%{"type" => "struct", "members" => %{"a" => %{}, "b" => %{}}}) ==
             "struct{2}"
  end

  test "spectrum/2 thins to min/max points and keeps peaks and dips" do
    values =
      for i <- 0..9_999 do
        cond do
          i == 5_000 -> 10.0
          i == 7_000 -> -3.0
          true -> 0.0
        end
      end

    {points, lo, hi} = ValueFormat.spectrum(values, 100)

    assert {lo, hi} == {-3.0, 10.0}
    assert length(points) <= 100
    assert [5_000, 10.0] in points
    assert [7_000, -3.0] in points
    assert points == Enum.sort(points)
  end

  test "spectrum/2 passes short arrays through" do
    assert ValueFormat.spectrum([1, 2.5, nil, 3]) == {[[0, 1], [1, 2.5], [3, 3]], 1, 3}
  end

  test "display_name/1 keeps existing capitals" do
    assert Util.display_name("MFC_group_1") == "MFC Group 1"
    assert Util.display_name("massflow_contr1") == "Massflow Contr1"
    assert Util.display_name("_pressure") == "Pressure"
  end
end
