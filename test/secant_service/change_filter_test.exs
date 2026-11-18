defmodule SecantService.NodeDBWriter.ChangeFilterTest do
  use ExUnit.Case, async: true

  alias SecantService.NodeDBWriter.ChangeFilter

  @heartbeat 600_000

  test "first value of a parameter is written" do
    assert {:write, _} = ChangeFilter.check(ChangeFilter.new(), :p, 1.0, 0, @heartbeat)
  end

  test "an unchanged value is skipped until the heartbeat is due" do
    {:write, f} = ChangeFilter.check(ChangeFilter.new(), :p, 1.0, 0, @heartbeat)
    assert {:skip, f} = ChangeFilter.check(f, :p, 1.0, 5_000, @heartbeat)
    assert {:skip, f} = ChangeFilter.check(f, :p, 1.0, @heartbeat - 1, @heartbeat)
    assert {:write, f} = ChangeFilter.check(f, :p, 1.0, @heartbeat, @heartbeat)
    # heartbeat restarts from the last write
    assert {:skip, _} = ChangeFilter.check(f, :p, 1.0, @heartbeat + 5_000, @heartbeat)
  end

  test "any change is written, compared with exact equality" do
    {:write, f} = ChangeFilter.check(ChangeFilter.new(), :p, 1.0, 0, @heartbeat)
    assert {:write, f} = ChangeFilter.check(f, :p, 1.0000001, 1, @heartbeat)
    # 1 and 1.0 are different terms
    assert {:write, _} = ChangeFilter.check(f, :p, 1, 2, @heartbeat)
  end

  test "large arrays are compared element by element" do
    spectrum = for i <- 1..10_000, do: i * 0.5
    {:write, f} = ChangeFilter.check(ChangeFilter.new(), :spec, spectrum, 0, @heartbeat)
    assert {:skip, f} = ChangeFilter.check(f, :spec, Enum.map(spectrum, & &1), 5_000, @heartbeat)

    changed = List.replace_at(spectrum, 9_999, 0.0)
    assert {:write, _} = ChangeFilter.check(f, :spec, changed, 10_000, @heartbeat)
  end

  test "parameters are tracked independently" do
    {:write, f} = ChangeFilter.check(ChangeFilter.new(), :a, 1, 0, @heartbeat)
    assert {:write, f} = ChangeFilter.check(f, :b, 1, 1, @heartbeat)
    assert {:skip, _} = ChangeFilter.check(f, :a, 1, 2, @heartbeat)
  end
end
