defmodule SecantService.PlotDB.HistoryTest do
  use SecantService.DataCase, async: false

  alias SecantService.SecNodes
  alias SecantService.PlotDB.Builders
  alias SecantService.PlotDB.History
  alias SecantService.Repo

  alias SecantService.SecNodes.{
    Module,
    Parameter,
    ParameterValueDouble,
    ParameterValueInt,
    SecNode
  }

  @start ~U[2026-03-01 00:00:00.000000Z]

  defp create_parameter(datainfo) do
    node =
      SecNode
      |> Ash.Changeset.for_create(:create, %{
        uuid: Ecto.UUID.generate(),
        equipment_id: "history_#{System.unique_integer([:positive])}",
        host: "localhost",
        port: 10_800
      })
      |> Ash.create!()

    module =
      Module
      |> Ash.Changeset.for_create(:create, %{name: "T", sec_node_id: node.uuid})
      |> Ash.create!()

    Parameter
    |> Ash.Changeset.for_create(:create, %{
      name: "value",
      datainfo: datainfo,
      module_id: module.id
    })
    |> Ash.create!()
  end

  # One reading per second from @start; `value_fun` maps the index to a value.
  defp insert_readings(parameter, resource, count, value_fun) do
    readings =
      for i <- 0..(count - 1) do
        %{
          parameter_id: parameter.id,
          value: value_fun.(i),
          timestamp: DateTime.add(@start, i, :second),
          qualifiers: %{}
        }
      end

    %Ash.BulkResult{status: :success} =
      Ash.bulk_create(readings, resource, :bulk_create, return_errors?: true)

    :ok
  end

  defp ms(index), do: DateTime.to_unix(@start, :millisecond) + index * 1000

  defp points(window), do: Enum.zip(window.timestamps, window.values)

  describe "numeric?/1" do
    test "only plain numbers are thinned out" do
      for type <- ["double", "int", "scaled"] do
        assert History.numeric?(%Parameter{datainfo: %{"type" => type}})
      end

      for type <- ["enum", "bool", "string", "array", "struct"] do
        refute History.numeric?(%Parameter{datainfo: %{"type" => type}})
      end
    end
  end

  describe "bucket_width/2" do
    test "picks the narrowest round width that needs no more buckets than allowed" do
      assert History.bucket_width(:timer.hours(1), 400) == :timer.seconds(10)
      assert History.bucket_width(:timer.hours(24), 400) == :timer.minutes(5)
      assert History.bucket_width(:timer.hours(24 * 10), 400) == :timer.hours(1)
      # beyond the list: whole days
      assert History.bucket_width(:timer.hours(24 * 2000), 400) == :timer.hours(24 * 5)
      assert History.bucket_width(0, 400) == 1
    end
  end

  describe "window/4" do
    test "a parameter without readings gives an empty window" do
      parameter = create_parameter(%{"type" => "double"})

      assert History.window(parameter, nil, nil) ==
               %{values: [], timestamps: [], aggregated: false, bucket_ms: nil}
    end

    test "few readings come back as stored, oldest first" do
      parameter = create_parameter(%{"type" => "double"})
      insert_readings(parameter, ParameterValueDouble, 50, &Decimal.new("#{&1}.5"))

      window = History.window(parameter, nil, nil, max_raw: 100)

      refute window.aggregated
      assert window.bucket_ms == nil
      assert points(window) == for(i <- 0..49, do: {ms(i), i + 0.5})
    end

    test "many readings are thinned out to real readings that keep the extremes" do
      parameter = create_parameter(%{"type" => "double"})

      # flat at 20, with one spike up and one dip down
      value = fn
        1234 -> Decimal.new("99.5")
        2345 -> Decimal.new("-7.25")
        _ -> Decimal.new("20.0")
      end

      insert_readings(parameter, ParameterValueDouble, 3600, value)

      window = History.window(parameter, nil, nil, max_raw: 100, max_buckets: 60)

      assert window.aggregated
      assert window.bucket_ms == :timer.minutes(1)
      # at most 4 readings per bucket
      assert length(window.values) <= 4 * 60
      assert length(window.values) < 3600

      points = points(window)
      assert {ms(1234), 99.5} in points
      assert {ms(2345), -7.25} in points
      # the first and last reading stay, so the time axis keeps its extent
      assert hd(points) == {ms(0), 20.0}
      assert List.last(points) == {ms(3599), 20.0}
      assert window.timestamps == Enum.sort(window.timestamps)
      assert window.timestamps == Enum.uniq(window.timestamps)
    end

    test "a smaller window gets narrower buckets and finally every reading" do
      parameter = create_parameter(%{"type" => "int"})
      insert_readings(parameter, ParameterValueInt, 3600, & &1)
      opts = [max_raw: 100, max_buckets: 60]

      assert %{aggregated: true, bucket_ms: 60_000} = History.window(parameter, nil, nil, opts)

      assert %{aggregated: true, bucket_ms: 10_000} =
               History.window(parameter, ms(600), ms(1200), opts)

      zoomed = History.window(parameter, ms(600), ms(650), opts)

      refute zoomed.aggregated
      assert points(zoomed) == for(i <- 600..650, do: {ms(i), i})
    end

    test "open ends reach to the first and last reading" do
      parameter = create_parameter(%{"type" => "int"})
      insert_readings(parameter, ParameterValueInt, 20, & &1)

      assert History.window(parameter, ms(15), nil).values == Enum.to_list(15..19)
      assert History.window(parameter, nil, ms(3)).values == Enum.to_list(0..3)
    end

    test "only the asked parameter's readings are used" do
      parameter = create_parameter(%{"type" => "int"})
      other = create_parameter(%{"type" => "int"})
      insert_readings(parameter, ParameterValueInt, 200, fn _ -> 1 end)
      insert_readings(other, ParameterValueInt, 200, fn _ -> 1000 end)

      window = History.window(parameter, nil, nil, max_raw: 50, max_buckets: 10)

      assert window.aggregated
      assert Enum.uniq(window.values) == [1]
    end

    test "compressed chunks give the same answer" do
      parameter = create_parameter(%{"type" => "double"})
      insert_readings(parameter, ParameterValueDouble, 600, &Decimal.new(rem(&1 * 7, 50)))
      opts = [max_raw: 100, max_buckets: 20]

      thinned = History.window(parameter, nil, nil, opts)
      zoomed = History.window(parameter, ms(100), ms(150), opts)

      %{rows: [_ | _]} =
        Repo.query!("SELECT compress_chunk(c) FROM show_chunks('parameter_values_double') c")

      assert History.window(parameter, nil, nil, opts) == thinned
      assert History.window(parameter, ms(100), ms(150), opts) == zoomed
    end
  end

  describe "resolution/4 and coarsest/1" do
    test "say how a window would be answered" do
      parameter = create_parameter(%{"type" => "int"})
      insert_readings(parameter, ParameterValueInt, 600, & &1)
      opts = [max_raw: 100, max_buckets: 60]

      assert History.resolution(parameter, nil, nil, opts) ==
               %{aggregated: true, bucket_ms: 10_000}

      assert History.resolution(parameter, ms(0), ms(50), opts) ==
               %{aggregated: false, bucket_ms: nil}
    end

    test "a plot of several parameters is as coarse as its coarsest one" do
      raw = %{aggregated: false, bucket_ms: nil}

      assert History.coarsest([raw, raw]) == raw
      assert History.coarsest([]) == raw

      assert History.coarsest([
               raw,
               %{aggregated: true, bucket_ms: 1000},
               %{aggregated: true, bucket_ms: 60_000}
             ]) == %{aggregated: true, bucket_ms: 60_000}
    end
  end

  describe "Parameter actions" do
    test ":history_window and :history_resolution answer like History" do
      parameter = create_parameter(%{"type" => "int"})
      insert_readings(parameter, ParameterValueInt, 600, & &1)
      limits = %{max_raw: 100, max_buckets: 60}

      thinned = SecNodes.history_window!(parameter.id, nil, nil, limits)
      assert thinned == History.window(parameter, nil, nil, Map.to_list(limits))
      assert thinned.aggregated

      assert SecNodes.history_resolution!(parameter.id, nil, nil, limits) ==
               %{aggregated: true, bucket_ms: 10_000}

      zoomed = SecNodes.history_window!(parameter.id, ms(10), ms(20))
      assert zoomed.values == Enum.to_list(10..20)
      refute zoomed.aggregated
    end

    test "refuse parameters that are not plain numbers, and unknown ones" do
      parameter = create_parameter(%{"type" => "string"})

      assert {:error, %Ash.Error.Invalid{}} = SecNodes.history_window(parameter.id, nil, nil)
      assert {:error, %Ash.Error.Invalid{}} = SecNodes.history_resolution(parameter.id, nil, nil)
      assert {:error, %Ash.Error.Invalid{}} = SecNodes.history_window(-1, nil, nil)
    end
  end

  describe "historical plot data" do
    test "numeric parameters are loaded thinned out" do
      parameter = create_parameter(%{"type" => "double"})
      insert_readings(parameter, ParameterValueDouble, 4000, &Decimal.new(rem(&1, 10)))

      {values, timestamps} = Builders.fetch_param_data(parameter, :historical)

      assert length(values) == length(timestamps)
      assert length(values) < 4000
      assert hd(timestamps) == ms(0)
      assert List.last(timestamps) == ms(3999)
    end
  end
end
