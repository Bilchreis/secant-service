defmodule SecantService.PlotDB.StoredReadingsTest do
  @moduledoc """
  The plot helpers that read stored readings: the array plot's latest
  reading, reading at a time and slider times, and the live plot's held
  setpoint and "any data" check.
  """
  use SecantService.DataCase, async: false

  alias SecantService.PlotDB.Builders
  alias SecantService.PlotDB.DTypes.ArrayLatest
  alias SecantService.SecNodes
  alias SecantService.SecNodes.Reading.Storage

  @t0 ~U[2026-01-01 00:00:00.000000Z]

  # one reading per second from @t0, value i for reading i
  defp insert(parameter, values) do
    rows =
      values
      |> Enum.with_index()
      |> Enum.map(fn {value, i} ->
        Storage.to_row(value, parameter, DateTime.add(@t0, i, :second), %{})
      end)

    %Ash.BulkResult{status: :success} = SecNodes.insert_readings(rows)
  end

  defp ms(seconds), do: DateTime.to_unix(@t0, :millisecond) + seconds * 1000

  describe "array plot" do
    setup do
      {:ok,
       parameter:
         generate(parameter(datainfo: %{"type" => "array", "members" => %{"type" => "double"}}))}
    end

    test "nothing stored", %{parameter: parameter} do
      assert ArrayLatest.fetch_latest(parameter) == nil
      assert ArrayLatest.fetch_at(parameter, ms(5)) == nil
      assert ArrayLatest.reading_times(parameter) == []
    end

    test "latest, at a time, and the slider times", %{parameter: parameter} do
      insert(parameter, [[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]])

      assert ArrayLatest.fetch_latest(parameter) == {[5.0, 6.0], ms(2)}
      # at a reading, and between two: the one at or before
      assert ArrayLatest.fetch_at(parameter, ms(1)) == {[3.0, 4.0], ms(1)}
      assert ArrayLatest.fetch_at(parameter, ms(1) + 500) == {[3.0, 4.0], ms(1)}
      assert ArrayLatest.fetch_at(parameter, ms(0) - 1) == nil
      assert ArrayLatest.reading_times(parameter) == [ms(0), ms(1), ms(2)]
    end
  end

  describe "live plot" do
    setup do
      {:ok, parameter: generate(parameter(datainfo: %{"type" => "double"}))}
    end

    test "any_data? and the held setpoint", %{parameter: parameter} do
      refute Builders.any_data?(parameter)
      assert Builders.hold_from(parameter, ms(10), [], []) == {[], []}

      insert(parameter, [1.0, 2.0, 3.0])

      assert Builders.any_data?(parameter)
      # the last reading before the window start, pinned to it
      assert Builders.hold_from(parameter, ms(10), [9.0], [ms(11)]) ==
               {[3.0, 9.0], [ms(10), ms(11)]}

      assert Builders.hold_from(parameter, ms(1) + 500, [], []) == {[2.0], [ms(1) + 500]}
      assert Builders.hold_from(parameter, ms(0), [], []) == {[], []}
    end

    test "a time range", %{parameter: parameter} do
      insert(parameter, [1.0, 2.0, 3.0, 4.0])

      assert Builders.fetch_param_data_in_range(parameter, ms(1), ms(2)) ==
               {[2.0, 3.0], [ms(1), ms(2)]}

      assert Builders.fetch_param_data_in_range(parameter, nil, nil) ==
               {[1.0, 2.0, 3.0, 4.0], [ms(0), ms(1), ms(2), ms(3)]}
    end
  end
end
