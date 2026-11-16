defmodule SecantServiceWeb.SparklineTest do
  use ExUnit.Case, async: true

  alias SecantServiceWeb.Components.Sparkline

  test "few readings pass through unchanged" do
    points = for i <- 1..50, do: {i * 1000, i * 1.0}
    assert Sparkline.thin(points, 120) == points
  end

  test "dense history is reduced to min/max per bucket and keeps spikes" do
    points = for i <- 0..5_999, do: {i * 100, if(i == 3_000, do: 9.0, else: 1.0)}
    thinned = Sparkline.thin(points, 120)

    assert length(thinned) <= 240
    assert {300_000, 9.0} in thinned
    # still in time order
    assert thinned == Enum.sort_by(thinned, &elem(&1, 0))
  end
end
