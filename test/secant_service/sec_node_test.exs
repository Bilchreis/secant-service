defmodule SecantService.SecNodeTest do
  use SecantService.DataCase, async: true

  alias SecantService.SecNodes
  alias SecantService.SecNodes.SecNode

  test "a node without a description can be read back" do
    uuid = Ecto.UUID.generate()

    SecNode
    |> Ash.Changeset.for_create(:create, %{
      uuid: uuid,
      equipment_id: "no_description",
      host: "localhost",
      port: 10_800
    })
    |> Ash.create!()

    # get_sec_node loads its calculations and the (empty) module tree
    assert %SecNode{description: nil, modules: []} = SecNodes.get_sec_node!(uuid)
  end
end
