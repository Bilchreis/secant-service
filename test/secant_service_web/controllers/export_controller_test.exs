defmodule SecantServiceWeb.ExportControllerTest do
  use SecantService.DataCase, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias SecantService.SecNodes.{Module, Parameter, ParameterValue, SecNode}

  @endpoint SecantServiceWeb.Endpoint

  @start ~U[2026-01-01 12:00:00.000000Z]

  @status_datainfo %{
    "type" => "tuple",
    "members" => [
      %{"type" => "enum", "members" => %{"IDLE" => 100, "BUSY" => 300}},
      %{"type" => "string"}
    ]
  }

  @parameters %{
    "value" => %{"type" => "double", "unit" => "K"},
    "status" => @status_datainfo,
    "ramp" => %{"type" => "scaled", "scale" => 0.1, "min" => 0, "max" => 1000, "unit" => "K/min"},
    "curve" => %{"type" => "array", "maxlen" => 3, "members" => %{"type" => "double"}},
    "mode" => %{"type" => "string"}
  }

  # One reading per second from @start, in SECoP wire format.
  @readings %{
    "value" => [4.2, 4.3, 4.5],
    "status" => [[100, "at target"], [300, "ramping"], [100, "at target"]],
    "ramp" => [10, 25, 25],
    "curve" => [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0], [7.0, 8.0, 9.0]],
    "mode" => ["auto", "manual", "auto"]
  }

  defp describe_message do
    accessibles =
      Map.new(@parameters, fn {name, datainfo} ->
        {name, %{"description" => name, "datainfo" => datainfo, "readonly" => true}}
      end)

    %{
      "equipment_id" => "test cryo",
      "description" => "test cryostat",
      "modules" => %{
        "T" => %{
          "description" => "sample temperature",
          "interface_classes" => ["Readable"],
          "meaning" => ["temperature", 10],
          "accessibles" => accessibles
        }
      }
    }
  end

  defp create_node(attrs \\ %{}) do
    node =
      SecNode
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(
          %{
            uuid: Ecto.UUID.generate(),
            equipment_id: "test cryo",
            description: "test cryostat",
            host: "localhost",
            port: 10_800,
            describe_message: describe_message()
          },
          attrs
        )
      )
      |> Ash.create!()

    module =
      Module
      |> Ash.Changeset.for_create(:create, %{name: "T", sec_node_id: node.uuid})
      |> Ash.create!()

    for {name, datainfo} <- @parameters do
      parameter =
        Parameter
        |> Ash.Changeset.for_create(:create, %{
          name: name,
          datainfo: datainfo,
          module_id: module.id
        })
        |> Ash.create!()

      @readings
      |> Map.fetch!(name)
      |> Enum.with_index()
      |> Enum.each(fn {value, i} ->
        value
        |> ParameterValue.create_changeset(parameter, DateTime.add(@start, i, :second))
        |> Ash.create!()
      end)
    end

    node
  end

  # Reads module T back out of the file with h5py: "logs" holds the values of
  # each `<parameter>_log` NXlog, "fields" the parameters written as a plain
  # field.
  defp read_nexus(file) do
    {result, _globals} =
      Pythonx.eval(
        """
        import io
        import h5py
        import numpy as np

        PARAMETERS = ["value", "status", "status_text", "ramp", "curve", "mode"]

        def plain(value):
            if isinstance(value, bytes):
                return value.decode()
            if isinstance(value, (np.ndarray, list)):
                return [plain(v) for v in value]
            return value.item() if isinstance(value, np.generic) else value

        with h5py.File(io.BytesIO(file), "r") as f:
            module = f["/entry/instrument/T"]
            sample = f["/entry/sample"]
            value = module["value_log/value"] if "value_log" in module else module["value"]
            result = {
                "module_class": plain(module.attrs["NX_class"]),
                "start_time": plain(f["/entry/start_time"][()]),
                "sample_log": plain(sample["temperature_log/value"][()])
                if "temperature_log" in sample
                else None,
                "sample_field": plain(sample["temperature"][()])
                if "temperature" in sample
                else None,
                "time": plain(module["value_log/time"][()]) if "value_log" in module else None,
                "unit": plain(value.attrs["units"]),
                "logs": {
                    name: plain(module[f"{name}_log/value"][()])
                    for name in PARAMETERS
                    if f"{name}_log" in module
                },
                "fields": {
                    name: plain(module[name][()])
                    for name in PARAMETERS
                    if isinstance(module.get(name), h5py.Dataset)
                },
            }
        result
        """,
        %{"file" => file}
      )

    Pythonx.decode(result)
  end

  describe "GET /export/node/:uuid" do
    test "returns the node's recorded data as a NeXus file" do
      node = create_node()

      conn = get(build_conn(), "/export/node/#{node.uuid}")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/x-hdf5"]

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="test-cryo_#{String.slice(node.uuid, 0, 8)}.nxs")
             ]

      assert <<0x89, "HDF\r\n", 0x1A, "\n", _::binary>> = conn.resp_body

      assert read_nexus(conn.resp_body) == %{
               "module_class" => "NXsensor",
               "start_time" => "2026-01-01T12:00:00+00:00",
               "sample_log" => [4.2, 4.3, 4.5],
               "sample_field" => nil,
               "time" => [0.0, 1.0, 2.0],
               "unit" => "K",
               # changing strings (status text, mode) are not written: an
               # NXlog holds numbers
               "logs" => %{
                 "value" => [4.2, 4.3, 4.5],
                 "status" => [100, 300, 100],
                 # scaled integers are stored as physical values
                 "ramp" => [1.0, 2.5, 2.5],
                 "curve" => [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0], [7.0, 8.0, 9.0]]
               },
               "fields" => %{}
             }
    end

    test "from/to restrict the exported time range" do
      node = create_node()
      from = DateTime.to_unix(@start, :millisecond) + 500

      conn = get(build_conn(), "/export/node/#{node.uuid}", %{from: from, to: from + 1000})

      assert conn.status == 200

      # a single reading per parameter never changes, so each one is a plain
      # field instead of an NXlog
      assert %{
               "logs" => logs,
               "fields" => fields,
               "sample_log" => nil,
               "sample_field" => 4.3,
               "unit" => "K"
             } = read_nexus(conn.resp_body)

      assert logs == %{}

      assert fields == %{
               "value" => 4.3,
               "status" => 300,
               "status_text" => "ramping",
               "ramp" => 2.5,
               "curve" => [4.0, 5.0, 6.0],
               "mode" => "manual"
             }
    end

    test "responds with 404 for an unknown or malformed uuid" do
      assert get(build_conn(), "/export/node/#{Ecto.UUID.generate()}").status == 404
      assert get(build_conn(), "/export/node/not-a-uuid").status == 404
    end

    test "responds with 404 when the node has no describe message" do
      node = create_node(%{describe_message: nil})

      assert get(build_conn(), "/export/node/#{node.uuid}").status == 404
    end
  end
end
