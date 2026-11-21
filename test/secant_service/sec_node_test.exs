defmodule SecantService.SecNodeTest do
  use SecantService.DataCase, async: true

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

    # the primary read loads the display calculations
    assert %SecNode{description: nil} = Ash.get!(SecNode, uuid)
  end
end
