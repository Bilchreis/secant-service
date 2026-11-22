defmodule SecantService.SecNodeTest do
  use SecantService.DataCase, async: true

  alias SecantService.SecNodes
  alias SecantService.SecNodes.SecNode

  test "a node without a description can be read back" do
    node = generate(sec_node(equipment_id: "no_description"))

    # get_sec_node loads its calculations and the (empty) module tree
    assert %SecNode{description: nil, modules: []} = SecNodes.get_sec_node!(node.uuid)
  end
end
