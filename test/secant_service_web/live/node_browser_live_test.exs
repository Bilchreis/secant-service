defmodule SecantServiceWeb.NodeBrowserLiveTest do
  use SecantService.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SecantServiceWeb.Endpoint

  test "the node header links to the NeXus export of the node" do
    node = generate(sec_node(equipment_id: "test cryo", description: "test cryostat"))

    {:ok, view, _html} = live(build_conn(), "/browse/node/#{node.uuid}")

    assert has_element?(view, ~s(#nexus-export[href="/export/node/#{node.uuid}"][download]))
  end
end
