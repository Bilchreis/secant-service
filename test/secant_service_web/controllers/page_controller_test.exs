defmodule SecantServiceWeb.PageControllerTest do
  use SecantServiceWeb.ConnCase, async: true

  alias SecantService.SecNodes

  test "the landing page links to the dashboard, the data browser and the sources", %{conn: conn} do
    doc = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    for {id, href} <- [
          {"#hero-dashboard", "/dashboard"},
          {"#hero-browse", "/browse"},
          {"#source-service-github", "https://github.com/Bilchreis/secant-service"},
          {"#source-client-github", "https://github.com/Bilchreis/secop_client"},
          {"#source-client-hex", "https://hex.pm/packages/secant_client"}
        ] do
      assert doc |> LazyHTML.query(id) |> LazyHTML.attribute("href") == [href]
    end
  end

  test "the overview counts recording sessions, their modules and kept sessions", %{conn: conn} do
    recording = generate(sec_node())
    generate(sec_module(sec_node_id: recording.uuid, name: "T_sample"))
    generate(sec_module(sec_node_id: recording.uuid, name: "heater"))

    archived = generate(sec_node()) |> SecNodes.archive_sec_node!()
    generate(sec_module(sec_node_id: archived.uuid))

    generate(sec_node()) |> SecNodes.archive_sec_node!() |> SecNodes.trash_sec_node!()

    doc = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    assert count(doc, "#count-recording") == "1"
    assert count(doc, "#count-modules") == "2"
    assert count(doc, "#count-sessions") == "2"
  end

  defp count(doc, selector),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
end
