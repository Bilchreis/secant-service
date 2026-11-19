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

  # Reads the logs of module T back out of the file with h5py.
  defp read_nexus(file) do
    {result, _globals} =
      Pythonx.eval(
        """
        import io
        import h5py

        def text(value):
            return value.decode() if isinstance(value, bytes) else value

        with h5py.File(io.BytesIO(file), "r") as f:
            module = f["/entry/instrument/T"]
            result = {
                "module_class": text(module.attrs["NX_class"]),
                "start_time": text(f["/entry/start_time"][()]),
                "sample_log": f["/entry/sample/temperature_log/value"][()].tolist(),
                "time": module["value_log/time"][()].tolist(),
                "value": module["value_log/value"][()].tolist(),
                "unit": text(module["value_log/value"].attrs["units"]),
                "status": module["status_log/value"][()].tolist(),
                "status_text": [text(v) for v in module["status_text_log/value"][()]],
                "ramp": module["ramp_log/value"][()].tolist(),
                "curve": module["curve_log/value"][()].tolist(),
                "mode": [text(v) for v in module["mode_log/value"][()]],
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
               "time" => [0.0, 1.0, 2.0],
               "value" => [4.2, 4.3, 4.5],
               "unit" => "K",
               "status" => [100, 300, 100],
               "status_text" => ["at target", "ramping", "at target"],
               # scaled integers are stored as physical values
               "ramp" => [1.0, 2.5, 2.5],
               "curve" => [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0], [7.0, 8.0, 9.0]],
               "mode" => ["auto", "manual", "auto"]
             }
    end

    test "from/to restrict the exported time range" do
      node = create_node()
      from = DateTime.to_unix(@start, :millisecond) + 500

      conn = get(build_conn(), "/export/node/#{node.uuid}", %{from: from, to: from + 1000})

      assert conn.status == 200
      assert %{"value" => [4.3], "mode" => ["manual"]} = read_nexus(conn.resp_body)
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
