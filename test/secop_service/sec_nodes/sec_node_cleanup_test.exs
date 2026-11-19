defmodule SecantService.SecNodes.SecNodeCleanupTest do
  use SecantService.DataCase, async: false

  use Oban.Testing, repo: SecantService.Repo

  alias SecantService.SecNodes.SecNode

  # Cleanup only targets archived, non-favourite nodes whose `updated_at` is
  # older than the retention period (see Calculations.ShouldCleanup).
  defp create_node(equipment_id, opts \\ []) do
    updated_at = Keyword.get(opts, :updated_at, DateTime.utc_now())
    state = Keyword.get(opts, :state, :archived)
    favourite = Keyword.get(opts, :favourite, false)

    SecNode
    |> Ash.Changeset.for_create(:create, %{
      uuid: Ecto.UUID.generate(),
      equipment_id: equipment_id,
      host: "192.168.1.1",
      port: 5000,
      description: "#{equipment_id} test node"
    })
    |> Ash.create!()
    |> Ecto.Changeset.change(state: state, favourite: favourite, updated_at: updated_at)
    |> SecantService.Repo.update!()
  end

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days, :day)

  defp retention_days, do: Application.get_env(:secant_service, :data_retention_days, 30)

  defp should_cleanup?(node), do: Ash.load!(node, :should_cleanup).should_cleanup

  describe "should_cleanup calculation" do
    test "is true for archived nodes older than the retention period" do
      old_node = create_node("old_equipment", updated_at: days_ago(retention_days() + 1))
      recent_node = create_node("recent_equipment")

      assert should_cleanup?(old_node)
      refute should_cleanup?(recent_node)
    end

    test "never cleans up active or favourite nodes, however old" do
      old = days_ago(retention_days() + 1)

      refute should_cleanup?(create_node("active", state: :active, updated_at: old))
      refute should_cleanup?(create_node("favourite", favourite: true, updated_at: old))
    end

    test "respects custom retention days" do
      original_retention = retention_days()

      try do
        Application.put_env(:secant_service, :data_retention_days, 7)

        assert should_cleanup?(create_node("ten_days", updated_at: days_ago(10)))
        refute should_cleanup?(create_node("five_days", updated_at: days_ago(5)))
      after
        Application.put_env(:secant_service, :data_retention_days, original_retention)
      end
    end

    test "boundary: node just inside the retention cutoff is not cleaned up" do
      # 1 minute buffer to avoid timing drift between setup and calculation
      cutoff = DateTime.add(DateTime.utc_now(), -(retention_days() * 86_400 - 60), :second)

      refute should_cleanup?(create_node("boundary_equipment", updated_at: cutoff))
    end
  end

  describe "cleanup_old_nodes job" do
    test "only trashes nodes that match the should_cleanup filter" do
      old = days_ago(retention_days() + 5)
      create_node("old_1", updated_at: old)
      create_node("old_2", updated_at: old)
      recent_node = create_node("recent")

      nodes_to_cleanup =
        SecNode
        |> Ash.Query.for_read(:read_for_cleanup)
        |> Ash.read!()
        |> Enum.filter(& &1.should_cleanup)

      assert length(nodes_to_cleanup) == 2

      # Simulate the trigger's :trash action
      Enum.each(nodes_to_cleanup, &SecNode.trash!/1)

      states = SecNode |> Ash.read!() |> Map.new(&{&1.uuid, &1.state})
      assert states[recent_node.uuid] == :archived
      assert states |> Map.values() |> Enum.count(&(&1 == :trashed)) == 2
    end
  end

  describe "AshOban worker configuration" do
    test "cleanup trigger trashes nodes on the nightly schedule" do
      trigger = Enum.find(AshOban.Info.oban_triggers(SecNode), &(&1.name == :cleanup_old_nodes))

      assert trigger != nil
      assert trigger.action == :trash
      assert trigger.read_action == :read_for_cleanup
      assert trigger.scheduler_cron == "0 2 * * *"
    end
  end
end
