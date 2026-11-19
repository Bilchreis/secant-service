defmodule SecantServiceWeb.NodeBrowserLiveTest do
  use SecantService.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SecantService.SecNodes.SecNode

  @endpoint SecantServiceWeb.Endpoint

  test "the node header links to the NeXus export of the node" do
    node =
      SecNode
      |> Ash.Changeset.for_create(:create, %{
        uuid: Ecto.UUID.generate(),
        equipment_id: "test cryo",
        description: "test cryostat",
        host: "localhost",
        port: 10_800
      })
      |> Ash.create!()

    {:ok, view, _html} = live(build_conn(), "/browse/node/#{node.uuid}")

    assert has_element?(view, ~s(#nexus-export[href="/export/node/#{node.uuid}"][download]))
  end
end
