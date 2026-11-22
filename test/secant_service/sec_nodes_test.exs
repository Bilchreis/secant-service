defmodule SecantService.SecNodesTest do
  @moduledoc """
  The domain interface: browsing, favourites, trash and purge, and the
  storage counts of the archive lifecycle.
  """
  use SecantService.DataCase, async: false

  require Ash.Query

  alias SecantService.SecNodes
  alias SecantService.SecNodes.{Parameter, SecNode}
  alias SecantService.SecNodes.Reading.Storage

  defp insert_values(parameter, count) do
    rows =
      for i <- 1..count do
        Storage.to_row(
          i * 1.0,
          parameter,
          DateTime.add(~U[2026-01-01 00:00:00.000000Z], i, :second),
          %{}
        )
      end

    %Ash.BulkResult{status: :success} = SecNodes.insert_readings(rows)
  end

  # Walk the node through the real lifecycle actions.
  defp set_state(node, :processed), do: SecNodes.archive_sec_node!(node)

  defp set_state(node, :archived),
    do: node |> set_state(:processed) |> Ash.update!(%{}, action: :finish_archiving)

  defp set_state(node, :trashed), do: node |> set_state(:archived) |> SecNodes.trash_sec_node!()

  defp uuids(nodes), do: nodes |> Enum.map(& &1.uuid) |> MapSet.new()

  describe "browse_sec_nodes/3" do
    test "each tab lists the nodes in that state" do
      {active, _} = node_with_parameter()
      {archived, _} = node_with_parameter()
      {trashed, _} = node_with_parameter()
      set_state(archived, :archived)
      set_state(trashed, :trashed)
      SecNodes.toggle_sec_node_favourite!(archived)

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

  test "get_sec_node loads the description; a parameter's node comes without it" do
    {node, parameter} = node_with_parameter()

    assert %SecNode{node_id: {~c"localhost", 10_800}, modules: [%{parameters: [_]}]} =
             SecNodes.get_sec_node!(node.uuid)

    # relationship loads use the plain primary read
    assert %{module: %{sec_node: %SecNode{node_id: {~c"localhost", 10_800}} = loaded}} =
             SecNodes.get_parameter!(parameter.id)

    assert %Ash.NotLoaded{} = loaded.modules
  end

  test "toggle_favourite flips the flag each time" do
    {node, _} = node_with_parameter()

    assert {:ok, %{favourite: true}} = SecNodes.toggle_sec_node_favourite(node)
    assert {:ok, %{favourite: false}} = SecNodes.toggle_sec_node_favourite(node)
  end

  test "purge deletes the trashed nodes and their values, nothing else" do
    {trashed_a, param_a} = node_with_parameter()
    {trashed_b, _} = node_with_parameter()
    {kept, kept_param} = node_with_parameter()
    insert_values(param_a, 5)
    insert_values(kept_param, 4)
    set_state(trashed_a, :trashed)
    set_state(trashed_b, :trashed)
    set_state(kept, :archived)

    assert {:ok, %{success: 2, failure: 0}} = SecNodes.purge_trashed_sec_nodes()

    assert {:ok, nil} = SecNodes.get_sec_node(trashed_a.uuid, not_found_error?: false)
    assert {:ok, nil} = SecNodes.get_sec_node(trashed_b.uuid, not_found_error?: false)
    assert {:ok, []} = SecNodes.readings(param_a.id)
    assert {:ok, %SecNode{state: :archived}} = SecNodes.get_sec_node(kept.uuid)
    assert {:ok, kept_values} = SecNodes.readings(kept_param.id)
    assert length(kept_values) == 4
  end

  test "readings, latest_reading and insert_readings" do
    {_node, parameter} = node_with_parameter()

    assert Storage.to_row(nil, parameter, DateTime.utc_now(), %{}) == nil
    assert %Ash.BulkResult{status: :success} = SecNodes.insert_readings([])
    assert {:ok, nil} = SecNodes.latest_reading(parameter.id)

    insert_values(parameter, 3)

    assert {:ok, %{value_float: 3.0}} = SecNodes.latest_reading(parameter.id)

    before = DateTime.add(~U[2026-01-01 00:00:00.000000Z], 2, :second)

    assert {:ok, %{value_float: 2.0}} =
             SecNodes.latest_reading(parameter.id, %{end_timestamp: before})

    assert {:ok, [%{timestamp: %DateTime{}, value_float: %Ash.NotLoaded{}} | _] = rows} =
             SecNodes.readings(parameter.id, %{order: :asc}, query: [select: [:timestamp]])

    assert length(rows) == 3
  end

  test "latest_reading asks the database for one row" do
    {_node, parameter} = node_with_parameter()
    insert_values(parameter, 3)

    ref = make_ref()
    me = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:secant_service, :repo, :query],
      fn _event, _measurements, %{query: sql}, _ -> send(me, {ref, sql}) end,
      nil
    )

    try do
      assert {:ok, %{value_float: 3.0}} = SecNodes.latest_reading(parameter.id)
    after
      :telemetry.detach({__MODULE__, ref})
    end

    # a get? interface adds no limit of its own: the action must
    assert_received {^ref, sql}
    assert sql =~ ~r/FROM "readings".*LIMIT/s
  end

  describe "storage counts" do
    test "finishing the archive counts the values and moves the node to archived" do
      {node, parameter} = node_with_parameter()
      insert_values(parameter, 7)
      node = set_state(node, :processed)

      archived = Ash.update!(node, %{}, action: :finish_archiving)

      assert archived.state == :archived
      assert {:ok, %{datapoint_count: 7}} = Ash.get(Parameter, parameter.id)
    end

    test "the hourly refresh counts the values of a recording node and keeps it active" do
      {node, parameter} = node_with_parameter()
      insert_values(parameter, 3)

      refreshed = Ash.update!(node, %{}, action: :refresh_storage)

      assert refreshed.state == :active
      assert {:ok, %{datapoint_count: 3}} = Ash.get(Parameter, parameter.id)
    end

    # logs the failed recount
    @tag :capture_log
    test "a failing size query keeps the old counts" do
      {node, parameter} = node_with_parameter()
      insert_values(parameter, 4)
      Ash.update!(node, %{}, action: :refresh_storage)

      assert {:ok, %{datapoint_count: 4, disk_size_bytes: size}} =
               Ash.get(Parameter, parameter.id)

      assert size > 0

      # more values, then a temp view shadowing `readings` in this (sandboxed,
      # rolled back) connection: pg_column_size(r) of its rows fails
      insert_values(parameter, 2)

      SecantService.Repo.query!(
        "CREATE TEMP VIEW readings AS SELECT id AS parameter_id, 1 / (id - id) AS boom FROM parameters"
      )

      assert %SecNode{state: :active} = Ash.update!(node, %{}, action: :refresh_storage)

      SecantService.Repo.query!("DROP VIEW pg_temp.readings")

      assert {:ok, %{datapoint_count: 4, disk_size_bytes: ^size}} =
               Ash.get(Parameter, parameter.id)
    end

    test "the on-archive trigger counts the values and archives the node" do
      {node, parameter} = node_with_parameter()
      insert_values(parameter, 6)
      SecNodes.archive_sec_node!(node)

      AshOban.Test.schedule_and_run_triggers({SecNode, :recalculate_storage_on_archive})

      assert {:ok, %{state: :archived}} = SecNodes.get_sec_node(node.uuid)
      assert {:ok, %{datapoint_count: 6}} = Ash.get(Parameter, parameter.id)
    end

    test "an active node cannot be finished" do
      {node, _} = node_with_parameter()
      assert {:error, _} = Ash.update(node, %{}, action: :finish_archiving)
    end
  end
end
