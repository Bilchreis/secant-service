defmodule SecantService.ReadingStorageTest do
  @moduledoc """
  Every SECoP type is stored in its column and comes back as the node sent
  it; a value that does not fit its declared type is kept, not dropped.
  """
  use SecantService.DataCase, async: true

  alias SecantService.SecNodes
  alias SecantService.SecNodes.{Module, Parameter, Reading, SecNode}
  alias SecantService.SecNodes.Reading.Storage

  @int %{"type" => "int"}
  @double %{"type" => "double"}

  # {datainfo, value as the node sent it (after JSON decoding), column}
  @cases [
    {@double, 21.5, :value_float},
    {@double, 3, :value_float},
    {@int, -7, :value_int},
    {%{"type" => "scaled", "scale" => 0.1}, 215, :value_int},
    {%{"type" => "enum", "members" => %{"off" => 0, "on" => 1}}, 1, :value_int},
    {%{"type" => "bool"}, false, :value_bool},
    {%{"type" => "string"}, "  padded and ünicode  ", :value_text},
    {%{"type" => "string"}, "", :value_text},
    {%{"type" => "array", "members" => @double}, [1.5, -2.0e-9, 0.0], :value_float_array},
    {%{"type" => "array", "members" => @int}, [1, 2, 3], :value_int_array},
    {%{"type" => "array", "members" => %{"type" => "bool"}}, [true, false], :value_bool_array},
    {%{"type" => "array", "members" => %{"type" => "string"}}, ["a", "", " b"],
     :value_text_array},
    {%{"type" => "array", "members" => %{"type" => "array", "members" => @int}}, [[1, 2], [3]],
     :value_json},
    {%{"type" => "struct", "members" => %{"x" => @double, "value" => @int}},
     %{"x" => 1.5, "value" => 2}, :value_json},
    {%{"type" => "tuple", "members" => [@int, %{"type" => "string"}]}, [1, "a"], :value_json},
    {%{"type" => "blob", "maxbytes" => 8}, "AAEC", :value_json},
    {%{"type" => "matrix", "names" => ["x"], "maxlen" => [2]}, %{"len" => [2], "blob" => "AAA="},
     :value_json},
    # does not fit the declared type: kept as sent
    {@int, 2.5, :value_json},
    {%{"type" => "array", "members" => @double}, [1.0, "oops"], :value_json}
  ]

  defp parameter(datainfo) do
    node =
      SecNode
      |> Ash.Changeset.for_create(:create, %{
        uuid: Ecto.UUID.generate(),
        equipment_id: "storage_#{System.unique_integer([:positive])}",
        host: "localhost",
        port: 10_800
      })
      |> Ash.create!()

    module =
      Module
      |> Ash.Changeset.for_create(:create, %{name: "m", sec_node_id: node.uuid})
      |> Ash.create!()

    Parameter
    |> Ash.Changeset.for_create(:create, %{name: "p", datainfo: datainfo, module_id: module.id})
    |> Ash.create!()
  end

  test "each type goes to its column and reads back as sent" do
    for {datainfo, value, column} <- @cases do
      parameter = parameter(datainfo)
      row = Storage.to_row(value, parameter, 1_700_000_000.5, %{e: 0.01})

      assert Map.has_key?(row, column), "#{inspect(value)} should go to #{column}"
      assert %Ash.BulkResult{status: :success} = SecNodes.insert_readings([row])

      assert [reading] = SecNodes.readings!(parameter)
      expected = if column == :value_float, do: value * 1.0, else: value
      assert Storage.raw_value(reading) == expected, "#{inspect(datainfo)}: #{inspect(value)}"
      assert reading.timestamp == ~U[2023-11-14 22:13:20.500000Z]
      assert Storage.same?(Storage.fingerprint(reading), Storage.fingerprint(row))
    end
  end

  test "struct keys decoded as atoms by the client are stored as strings" do
    parameter = parameter(%{"type" => "struct", "members" => %{"x" => @double}})
    row = Storage.to_row(%{x: 1.5}, parameter, 1_700_000_000.0, %{})
    SecNodes.insert_readings([row])

    assert [reading] = SecNodes.readings!(parameter)
    assert Storage.raw_value(reading) == %{"x" => 1.5}
    assert Storage.same?(Storage.fingerprint(reading), Storage.fingerprint(row))
  end

  test "one batch can hold readings of different columns" do
    float = parameter(@double)
    text = parameter(%{"type" => "string"})
    spectrum = parameter(%{"type" => "array", "members" => @double})

    rows = [
      Storage.to_row(1.5, float, 1_700_000_000.0, %{}),
      Storage.to_row("on", text, 1_700_000_000.0, %{}),
      Storage.to_row([1.0, 2.0], spectrum, 1_700_000_000.0, %{})
    ]

    assert %Ash.BulkResult{status: :success} = SecNodes.insert_readings(rows)

    assert [[1.5], ["on"], [[1.0, 2.0]]] ==
             Enum.map([float, text, spectrum], fn p ->
               p |> SecNodes.readings!() |> Enum.map(&Storage.raw_value/1)
             end)
  end

  test "latest_readings: newest per parameter, the last stored on a tie, none for no readings" do
    a = parameter(@double)
    b = parameter(@double)
    empty = parameter(@double)

    SecNodes.insert_readings([
      Storage.to_row(1.0, a, 1_700_000_000.0, %{}),
      Storage.to_row(2.0, a, 1_700_000_005.0, %{}),
      Storage.to_row(3.0, b, 1_700_000_005.0, %{})
    ])

    # same timestamp, different value: both stored, the later one is "last"
    SecNodes.insert_readings([Storage.to_row(4.0, b, 1_700_000_005.0, %{})])

    latest = SecNodes.latest_readings([a.id, b.id, empty.id])

    assert Storage.raw_value(latest[a.id]) == 2.0
    assert Storage.raw_value(latest[b.id]) == 4.0
    refute Map.has_key?(latest, empty.id)
    assert SecNodes.latest_readings([]) == %{}
  end

  test "qualifiers are stored, except t" do
    p = parameter(@double)

    SecNodes.insert_readings([
      Storage.to_row(1.0, p, 1_700_000_000.0, %{t: 1_700_000_000.0, e: 0.01})
    ])

    assert [%{qualifiers: %{"e" => 0.01} = qualifiers}] = SecNodes.readings!(p)
    refute Map.has_key?(qualifiers, "t")
  end

  test "values and qualifiers with a NUL character are stored as sent" do
    for {datainfo, value} <- [
          {%{"type" => "string"}, "a\u0000b"},
          {%{"type" => "array", "members" => %{"type" => "string"}}, ["ok", "\u0000"]},
          {%{"type" => "struct", "members" => %{"s" => %{"type" => "string"}}},
           %{"s" => "x\u0000"}}
        ] do
      p = parameter(datainfo)
      row = Storage.to_row(value, p, 1_700_000_000.0, %{"note" => "q\u0000"})

      assert %Ash.BulkResult{status: :success} = SecNodes.insert_readings([row])
      assert [reading] = SecNodes.readings!(p)
      assert Storage.raw_value(reading) == value
      assert Storage.same?(Storage.fingerprint(reading), Storage.fingerprint(row))
      assert Storage.qualifiers(reading) == %{"note" => "q\u0000"}
    end
  end

  test "values a column can't hold are kept in value_json" do
    huge = Bitwise.bsl(1, 70)
    p = parameter(@int)
    row = Storage.to_row(huge, p, 1_700_000_000.0, %{})

    assert Map.has_key?(row, :value_json)
    SecNodes.insert_readings([row])
    assert [reading] = SecNodes.readings!(p)
    assert Storage.raw_value(reading) == huge
  end

  describe "the history table (AshPagify over :for_parameter)" do
    setup do
      p = parameter(@double)

      SecNodes.insert_readings(
        for {v, i} <- Enum.with_index([3.0, 1.0, 2.0]) do
          Storage.to_row(v, p, 1_700_000_000.0 + i, %{})
        end
      )

      {:ok, parameter: p}
    end

    defp page(parameter, order_by) do
      {:ok, {readings, meta}} =
        AshPagify.validate_and_run(
          Reading,
          %{limit: 20, page: 1, order_by: order_by},
          [action: :for_parameter],
          %{parameter_id: parameter.id}
        )

      {Enum.map(readings, &Storage.raw_value/1), meta.total_count}
    end

    test "newest first", %{parameter: p} do
      assert page(p, ["-timestamp"]) == {[2.0, 1.0, 3.0], 3}
    end

    test "sorted by the parameter's value column", %{parameter: p} do
      assert page(p, [Atom.to_string(Storage.column(p))]) == {[1.0, 2.0, 3.0], 3}
    end
  end

  test "the column is chosen from the datainfo" do
    assert Storage.column(@double) == :value_float
    assert Storage.column(%{"type" => "scaled"}) == :value_int

    assert Storage.column(%{"type" => "array", "members" => %{"type" => "enum"}}) ==
             :value_int_array

    assert Storage.column(%{"type" => "struct"}) == :value_json
    assert Storage.column(%{}) == :value_json
  end
end
