defmodule SecantService.SecNodesTest do
  @moduledoc """
  The domain interface: browsing, favourites, trash and purge, and the
  storage counts of the archive lifecycle.
  """
  use SecantService.DataCase, async: false

  require Ash.Query

  alias SecantService.SecNodes
  alias SecantService.SecNodes.{Module, Parameter, SecNode}

  defp create_node(attrs \\ %{}) do
    node =
      SecNode
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(
          %{
            uuid: Ecto.UUID.generate(),
            equipment_id: "node_#{System.unique_integer([:positive])}",
            host: "localhost",
            port: 10_800
          },
          attrs
        )
      )
      |> Ash.create!()

    module =
      Module
      |> Ash.Changeset.for_create(:create, %{name: "m", sec_node_id: node.uuid})
      |> Ash.create!()

    parameter =
      Parameter
      |> Ash.Changeset.for_create(:create, %{
        name: "value",
        datainfo: %{"type" => "double"},
        module_id: module.id
      })
      |> Ash.create!()

    {node, parameter}
  end

  defp insert_values(parameter, count) do
    rows =
      for i <- 1..count do
        %{
          parameter_id: parameter.id,
          value: i * 1.0,
          timestamp: DateTime.add(~U[2026-01-01 00:00:00.000000Z], i, :second),
          qualifiers: %{}
        }
      end

    %Ash.BulkResult{status: :success} = SecNodes.insert_readings(:double, rows)
  end

  # Walk the node through the real lifecycle actions.
  defp set_state(node, :processed), do: SecNodes.archive_sec_node!(node)

  defp set_state(node, :archived),
    do: node |> set_state(:processed) |> Ash.update!(%{}, action: :finish_archiving)

  defp set_state(node, :trashed), do: node |> set_state(:archived) |> SecNodes.trash_sec_node!()

  defp uuids(nodes), do: nodes |> Enum.map(& &1.uuid) |> MapSet.new()

  describe "browse_sec_nodes/3" do
    test "each tab lists the nodes in that state" do
      {active, _} = create_node()
      {archived, _} = create_node()
      {trashed, _} = create_node()
      set_state(archived, :archived)
      set_state(trashed, :trashed)
      {:ok, _} = SecNodes.toggle_sec_node_favourite(archived)

      ids = MapSet.new([active.uuid, archived.uuid, trashed.uuid])

      tab = fn filter ->
        {:ok, {nodes, _meta}} = SecNodes.browse_sec_nodes(filter, %{"limit" => 100})
        MapSet.intersection(uuids(nodes), ids)
      end

      assert tab.(:active) == MapSet.new([active.uuid])
      assert tab.(:archived) == MapSet.new([archived.uuid])
      assert tab.(:trashed) == MapSet.new([trashed.uuid])
      assert tab.(:favourite) == MapSet.new([archived.uuid])
      assert tab.(:all) == ids

      # the page count is that of the tab, not of all nodes
      {:ok, {_nodes, meta}} = SecNodes.browse_sec_nodes(:trashed, %{"limit" => 1})
      assert meta.total_count == Ash.count!(Ash.Query.filter(SecNode, state == :trashed))
      assert meta.total_count < Ash.count!(SecNode)
    end
  end

  test "toggle_favourite flips the flag each time" do
    {node, _} = create_node()

    assert {:ok, %{favourite: true}} = SecNodes.toggle_sec_node_favourite(node)
    assert {:ok, %{favourite: false}} = SecNodes.toggle_sec_node_favourite(node)
  end

  test "purge deletes the trashed nodes and their values, nothing else" do
    {trashed_a, param_a} = create_node()
    {trashed_b, _} = create_node()
    {kept, kept_param} = create_node()
    insert_values(param_a, 5)
    insert_values(kept_param, 4)
    set_state(trashed_a, :trashed)
    set_state(trashed_b, :trashed)
    set_state(kept, :archived)

    assert {:ok, %{success: 2, failure: 0}} = SecNodes.purge_trashed_sec_nodes()

    assert {:ok, nil} = SecNodes.get_sec_node(trashed_a.uuid, not_found_error?: false)
    assert {:ok, nil} = SecNodes.get_sec_node(trashed_b.uuid, not_found_error?: false)
    assert {:ok, []} = SecNodes.readings(param_a)
    assert {:ok, %SecNode{state: :archived}} = SecNodes.get_sec_node(kept.uuid)
    assert {:ok, kept_values} = SecNodes.readings(kept_param)
    assert length(kept_values) == 4
  end

  test "readings, latest_reading and insert_readings" do
    {_node, parameter} = create_node()

    nil_row = %{
      parameter_id: parameter.id,
      value: nil,
      timestamp: DateTime.utc_now(),
      qualifiers: %{}
    }

    assert %Ash.BulkResult{status: :success} = SecNodes.insert_readings(:double, [nil_row])
    assert {:ok, nil} = SecNodes.latest_reading(parameter)

    insert_values(parameter, 3)

    assert {:ok, %{value: newest}} = SecNodes.latest_reading(parameter)
    assert Decimal.equal?(newest, Decimal.new("3.0"))

    before = DateTime.add(~U[2026-01-01 00:00:00.000000Z], 2, :second)
    assert {:ok, %{value: second}} = SecNodes.latest_reading(parameter, %{end_timestamp: before})
    assert Decimal.equal?(second, Decimal.new("2.0"))

    assert {:ok, [%{timestamp: %DateTime{}} | _] = rows} =
             SecNodes.readings(parameter, %{order: :asc}, select: [:timestamp])

    assert length(rows) == 3
    assert_raise ArgumentError, fn -> SecNodes.readings(parameter, %{}, load: [:parameter]) end
  end

  describe "storage counts" do
    test "finishing the archive counts the values and moves the node to archived" do
      {node, parameter} = create_node()
      insert_values(parameter, 7)
      node = set_state(node, :processed)

      archived = Ash.update!(node, %{}, action: :finish_archiving)

      assert archived.state == :archived
      assert {:ok, %{datapoint_count: 7}} = Ash.get(Parameter, parameter.id)
    end

    test "the hourly refresh counts the values of a recording node and keeps it active" do
      {node, parameter} = create_node()
      insert_values(parameter, 3)

      refreshed = Ash.update!(node, %{}, action: :refresh_storage)

      assert refreshed.state == :active
      assert {:ok, %{datapoint_count: 3}} = Ash.get(Parameter, parameter.id)
    end

    test "the on-archive trigger counts the values and archives the node" do
      {node, parameter} = create_node()
      insert_values(parameter, 6)
      SecNodes.archive_sec_node!(node)

      AshOban.Test.schedule_and_run_triggers({SecNode, :recalculate_storage_on_archive})

      assert {:ok, %{state: :archived}} = SecNodes.get_sec_node(node.uuid)
      assert {:ok, %{datapoint_count: 6}} = Ash.get(Parameter, parameter.id)
    end

    test "an active node cannot be finished" do
      {node, _} = create_node()
      assert {:error, _} = Ash.update(node, %{}, action: :finish_archiving)
    end
  end
end
