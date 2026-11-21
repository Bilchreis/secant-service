defmodule SecantServiceWeb.DataBrowserLiveTest do
  @moduledoc "The data browser: tabs, favourite, trash and restore."
  use SecantServiceWeb.ConnCase, async: false

  alias SecantService.SecNodes
  alias SecantService.SecNodes.SecNode

  defp create_node do
    SecNode
    |> Ash.Changeset.for_create(:create, %{
      uuid: Ecto.UUID.generate(),
      equipment_id: "browse_#{System.unique_integer([:positive])}",
      host: "localhost",
      port: 10_800
    })
    |> Ash.create!()
  end

  defp archived_node do
    create_node()
    |> SecNodes.archive_sec_node!()
    |> Ash.update!(%{}, action: :finish_archiving)
  end

  test "the active tab lists active nodes only", %{conn: conn} do
    active = create_node()
    archived = archived_node()

    {:ok, view, _html} = live(conn, "/browse?state_filter=active&limit=100")

    assert has_element?(view, "#uuid-#{active.uuid}")
    refute has_element?(view, "#uuid-#{archived.uuid}")
  end

  test "favourite, trash and restore an archived node", %{conn: conn} do
    node = archived_node()
    {:ok, view, _html} = live(conn, "/browse?state_filter=archived&limit=100")

    view |> element("#fav-btn-#{node.uuid}") |> render_click()
    assert {:ok, %{favourite: true}} = SecNodes.get_sec_node(node.uuid)

    view |> element("#trash-btn-#{node.uuid}") |> render_click()
    assert {:ok, %{state: :trashed}} = SecNodes.get_sec_node(node.uuid)

    {:ok, view, _html} = live(conn, "/browse?state_filter=trashed&limit=100")
    view |> element("#restore-btn-#{node.uuid}") |> render_click()
    assert {:ok, %{state: :archived}} = SecNodes.get_sec_node(node.uuid)
  end
end
