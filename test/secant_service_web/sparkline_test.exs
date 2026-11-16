defmodule SecantServiceWeb.SparklineTest do
  use ExUnit.Case, async: true

  alias SecantServiceWeb.Components.Sparkline

  @now 1_000_000_000

  defp coords(line), do: line |> String.split(" ") |> length()

  test "no readings draws nothing" do
    assert Sparkline.polyline([], @now) == nil
  end

  test "sparse readings are drawn as steps up to now" do
    points = [{@now - 120_000, 0.0}, {@now - 60_000, 30.0}]
    line = Sparkline.polyline(points, @now)

    # start, step corner, new level, extended to now
    assert coords(line) == 4
    assert String.starts_with?(line, "0.0,29.0")
    assert String.ends_with?(line, "200.0,3.0")
  end

  test "dense readings are reduced to min/max per bucket" do
    points = for i <- 0..599, do: {@now - 600_000 + i * 1000, if(i == 300, do: 9.0, else: 1.0)}
    line = Sparkline.polyline(points, @now)

    assert coords(line) <= 2 * 100 + 1
    # the one-sample spike is still the top of the line
    assert line =~ ",3.0"
  end

  test "a constant value sits in the middle" do
    line = Sparkline.polyline([{@now - 30_000, 5.0}, {@now - 10_000, 5.0}], @now)
    assert line |> String.split(" ") |> Enum.all?(&String.ends_with?(&1, ",16.0"))
  end
end
