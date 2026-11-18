defmodule SecantService.PlotDB.BuildersTest do
  use SecantService.DataCase, async: false

  alias SecantService.PlotDB.Builders
  alias SecantService.SecNodes.{Module, Parameter, ParameterValueDouble, SecNode}

  setup do
    node =
      SecNode
      |> Ash.Changeset.for_create(:create, %{
        uuid: Ecto.UUID.generate(),
        equipment_id: "test_node",
        host: "localhost",
        port: 10_767,
        description: "test"
      })
      |> Ash.create!()

    module =
      Module
      |> Ash.Changeset.for_create(:create, %{
        name: "temp",
        description: "test",
        interface_classes: ["Drivable"],
        sec_node_id: node.uuid
      })
      |> Ash.create!()

    param =
      Parameter
      |> Ash.Changeset.for_create(:create, %{
        name: "target",
        datainfo: %{"type" => "double"},
        readonly: false,
        description: "test",
        module_id: module.id
      })
      |> Ash.create!()

    %{param: param}
  end

  defp insert(param, value, ms) do
    ParameterValueDouble
    |> Ash.Changeset.for_create(:create, %{
      parameter_id: param.id,
      value: value,
      timestamp: DateTime.from_unix!(ms, :millisecond)
    })
    |> Ash.create!()
  end

  # double values come back as Decimal
  defp fetch(param, from, to) do
    {vals, ts} = Builders.fetch_param_data_in_range(param, from, to)
    {Enum.map(vals, &Decimal.to_float/1), ts}
  end

  test "includes the value in effect at the window start as an anchor", %{param: param} do
    insert(param, 1.0, 1_000)
    insert(param, 2.0, 5_000)
    insert(param, 3.0, 20_000)

    assert {[2.0, 3.0], [10_000, 20_000]} =
             fetch(param, 10_000, 30_000)
  end

  test "a value unchanged for longer than the window is still returned", %{param: param} do
    insert(param, 42.0, 1_000)

    assert {[42.0], [10_000]} = fetch(param, 10_000, 30_000)
  end

  test "no anchor without a window start or without earlier data", %{param: param} do
    insert(param, 1.0, 1_000)
    insert(param, 2.0, 20_000)

    assert {[1.0, 2.0], [1_000, 20_000]} = fetch(param, nil, nil)
    assert {[1.0, 2.0], [1_000, 20_000]} = fetch(param, 1_000, nil)
  end

  test "a single stored value is enough to plot", %{param: param} do
    assert Builders.plot_available?([42.0], param, :historical)
    refute Builders.plot_available?([], param, :historical)
  end
end
