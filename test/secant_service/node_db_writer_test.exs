defmodule SecantService.NodeDBWriterTest do
  use SecantService.DataCase, async: false

  alias SecantService.NodeDBWriter
  alias SecantService.SecNodes.{Module, Parameter, ParameterValueArrayDouble, SecNode}

  setup do
    node =
      SecNode
      |> Ash.Changeset.for_create(:create, %{
        uuid: Ecto.UUID.generate(),
        equipment_id: "ftir",
        host: "localhost",
        port: 10_799,
        description: "test"
      })
      |> Ash.create!()
      |> Ash.load!([:values_pubsub_topic, :node_id])

    module =
      Module
      |> Ash.Changeset.for_create(:create, %{
        name: "spectrometer",
        description: "test",
        interface_classes: ["Readable"],
        sec_node_id: node.uuid
      })
      |> Ash.create!()

    param =
      Parameter
      |> Ash.Changeset.for_create(:create, %{
        name: "spectrum",
        datainfo: %{"type" => "array", "members" => %{"type" => "double"}},
        readonly: true,
        description: "test",
        module_id: module.id
      })
      |> Ash.create!()

    # no NodeValues process in tests: initial values are skipped with a log line
    pid = start_supervised!({NodeDBWriter, node})

    %{pid: pid, param: param}
  end

  defp send_update(pid, value) do
    send(pid, {:value_update, "spectrometer", "spectrum", [value, %{}]})
  end

  defp read_rows(param) do
    ParameterValueArrayDouble
    |> Ash.Query.for_read(:for_parameter, %{parameter_id: param.id})
    |> Ash.read!()
  end

  # The flush inserts from a Task; poll until it has landed.
  defp rows_after_flush(param, attempts \\ 50) do
    case read_rows(param) do
      [] when attempts > 0 ->
        Process.sleep(20)
        rows_after_flush(param, attempts - 1)

      rows ->
        rows
    end
  end

  test "repeated identical arrays are stored once, a change is stored", %{pid: pid, param: param} do
    spectrum = for i <- 1..10_000, do: i * 0.5

    for _ <- 1..20, do: send_update(pid, spectrum)
    send_update(pid, List.replace_at(spectrum, 0, 99.0))
    send_update(pid, List.replace_at(spectrum, 0, 99.0))
    send(pid, :flush_parameter_batch)

    # all rows of one flush are inserted in a single bulk insert
    rows = rows_after_flush(param)

    assert Enum.map(rows, &hd(&1.value)) == [0.5, 99.0]
  end
end
