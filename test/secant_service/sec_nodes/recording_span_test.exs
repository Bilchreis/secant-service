defmodule SecantService.SecNodes.RecordingSpanTest do
  use SecantService.DataCase, async: true

  alias SecantService.SecNodes
  alias SecantService.SecNodes.RecordingSpan

  defp at(seconds), do: DateTime.add(~U[2026-11-27 08:00:00.000000Z], seconds, :second)

  defp span(node, attrs \\ %{}) do
    Map.merge(
      %{id: Ecto.UUID.generate(), sec_node_id: node.uuid, started_at: at(0), alive_until: at(0)},
      attrs
    )
  end

  defp stored(id), do: Ash.get!(RecordingSpan, id)

  test "an upsert by id updates the span in place" do
    node = generate(sec_node())
    attrs = span(node)
    SecNodes.record_span!(attrs)
    SecNodes.record_span!(%{attrs | alive_until: at(10)})

    assert [%{alive_until: alive}] = Ash.read!(RecordingSpan)
    assert alive == at(10)
  end

  test "a closed span is never changed again" do
    node = generate(sec_node())
    attrs = span(node)
    SecNodes.record_span!(Map.merge(attrs, %{ended_at: at(5), end_reason: :disconnected}))

    # a late heartbeat, and a second close
    SecNodes.record_span!(%{attrs | alive_until: at(20)})

    SecNodes.record_span!(
      Map.merge(attrs, %{alive_until: at(30), ended_at: at(30), end_reason: :stopped})
    )

    span = stored(attrs.id)
    assert span.alive_until == at(0)
    assert span.ended_at == at(5)
    assert span.end_reason == :disconnected
  end

  test "a session has at most one open span" do
    node = generate(sec_node())
    SecNodes.record_span!(span(node))

    assert {:error, _} =
             SecNodes.record_span(span(node, %{started_at: at(60), alive_until: at(60)}))

    # a closed one next to it is fine
    assert {:ok, _} =
             SecNodes.record_span(span(node, %{ended_at: at(1), end_reason: :stopped}))
  end

  test "the open span of a session" do
    node = generate(sec_node())
    other = generate(sec_node())
    closed = span(node, %{ended_at: at(1), end_reason: :stopped})
    open = span(node, %{started_at: at(10), alive_until: at(10)})
    SecNodes.record_span!(closed)
    SecNodes.record_span!(open)
    SecNodes.record_span!(span(other))

    assert SecNodes.open_span!(node.uuid).id == open.id
    assert SecNodes.open_span!(generate(sec_node()).uuid) == nil
  end

  test "spans are deleted with their session" do
    node = generate(sec_node())
    SecNodes.record_span!(span(node))

    Ash.destroy!(node)

    assert Ash.read!(RecordingSpan) == []
  end
end
