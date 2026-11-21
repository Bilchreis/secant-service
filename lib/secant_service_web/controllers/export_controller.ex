defmodule SecantServiceWeb.ExportController do
  @moduledoc """
  Downloads of recorded data for analysis outside SECAnT.

  `GET /export/parameter/:id` returns every recorded value of one parameter
  as CSV (UTC ISO 8601 timestamp, value). Optional `from`/`to` query
  parameters (Unix milliseconds) restrict the time range. Non-scalar values
  are written as JSON in the value column.

  `GET /export/node/:uuid` returns everything recorded for one SEC node as a
  NeXus (HDF5) file, see `SecantService.NexusExport`. It takes the same
  `from`/`to` parameters.
  """
  use SecantServiceWeb, :controller

  alias SecantService.NexusExport
  alias SecantService.SecNodes
  alias SecantService.SecNodes.Parameter
  alias SecantService.SecNodes.ParameterValue
  alias SecantService.SecNodes.SecNode

  def parameter(conn, %{"id" => id} = params) do
    with {id, ""} <- Integer.parse(id),
         %Parameter{} = parameter <- get_parameter(id) do
      values = SecNodes.readings!(parameter, read_args(params))

      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{filename(parameter)}")
      )
      |> send_resp(200, to_csv(values, parameter))
    else
      _ -> send_resp(conn, 404, "parameter not found")
    end
  end

  def node(conn, %{"uuid" => uuid} = params) do
    with {:ok, %SecNode{} = node} <- SecNodes.get_sec_node(uuid, not_found_error?: false),
         {:ok, file} <- NexusExport.node_file(node, time_range(params)) do
      conn
      |> put_resp_content_type("application/x-hdf5", nil)
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{node_filename(node)}")
      )
      |> send_resp(200, file)
    else
      {:error, :failed} -> send_resp(conn, 500, "NeXus export failed")
      {:error, :no_description} -> send_resp(conn, 404, "node has no describe message")
      _ -> send_resp(conn, 404, "node not found")
    end
  end

  defp get_parameter(id) do
    case SecNodes.get_parameter(id, not_found_error?: false) do
      {:ok, parameter} -> parameter
      _ -> nil
    end
  end

  defp read_args(params), do: Map.put(time_range(params), :order, :asc)

  defp time_range(params) do
    %{}
    |> put_time(:start_timestamp, params["from"])
    |> put_time(:end_timestamp, params["to"])
  end

  defp put_time(args, key, ms) when is_binary(ms) do
    case Integer.parse(ms) do
      {ms, ""} -> Map.put(args, key, DateTime.from_unix!(ms, :millisecond))
      _ -> args
    end
  end

  defp put_time(args, _key, _), do: args

  defp filename(parameter) do
    node_parts(parameter.module.sec_node)
    |> Kernel.++([parameter.module.name, parameter.name])
    |> join_filename(".csv")
  end

  defp node_filename(node), do: node |> node_parts() |> join_filename(".nxs")

  defp node_parts(node) do
    [node.equipment_id || "node", node.uuid |> to_string() |> String.slice(0, 8)]
  end

  defp join_filename(parts, extension) do
    Enum.map_join(parts, "_", &String.replace(to_string(&1), ~r/[^\w.-]+/, "-")) <> extension
  end

  defp to_csv(values, parameter) do
    unit = parameter.datainfo["unit"]
    value_header = if unit in [nil, ""], do: parameter.name, else: "#{parameter.name} [#{unit}]"

    rows =
      Enum.map(values, fn pv ->
        [
          timestamp(pv.timestamp),
          ",",
          csv_field(ParameterValue.get_raw_value(pv, parameter)),
          "\n"
        ]
      end)

    IO.iodata_to_binary(["timestamp_utc,", csv_field(value_header), "\n" | rows])
  end

  defp timestamp(%DateTime{} = ts), do: DateTime.to_iso8601(ts)
  defp timestamp(%NaiveDateTime{} = ts), do: NaiveDateTime.to_iso8601(ts) <> "Z"

  defp csv_field(value) when is_number(value), do: to_string(value)
  defp csv_field(%Decimal{} = value), do: Decimal.to_string(value)
  defp csv_field(value) when is_boolean(value), do: to_string(value)
  defp csv_field(nil), do: ""
  defp csv_field(value) when is_binary(value), do: quote_csv(value)
  defp csv_field(value), do: value |> Jason.encode!() |> quote_csv()

  defp quote_csv(text), do: ~s(") <> String.replace(text, ~s("), ~s("")) <> ~s(")
end
