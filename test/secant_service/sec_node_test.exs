defmodule SecantService.SecNodeTest do
  use SecantService.DataCase, async: true

  alias SecantService.SecNodes
  alias SecantService.SecNodes.SecNode

  test "a node without a description can be read back" do
    node = generate(sec_node(equipment_id: "no_description"))

    # get_sec_node loads its calculations and the (empty) module tree
    assert %SecNode{description: nil, modules: []} = SecNodes.get_sec_node!(node.uuid)
  end

  test "node_id loads the address it needs, whatever the query selects" do
    uuid = Ecto.UUID.generate()

    SecNode
    |> Ash.Changeset.for_create(:create, %{
      uuid: uuid,
      equipment_id: "selected",
      host: "10.0.0.7",
      port: 10_767
    })
    |> Ash.create!()

    assert %SecNode{node_id: {~c"10.0.0.7", 10_767}} =
             SecNodes.get_sec_node!(uuid, query: [select: [:uuid]], load: [:node_id])
  end
end
