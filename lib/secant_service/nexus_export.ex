defmodule SecantService.NexusExport do
  @moduledoc """
  Writes the recorded data of one SEC node as a NeXus (HDF5) file.

  The file is built by the `secop-to-nexus` Python package from the node's
  describe message and the recorded history of every parameter: one
  `NXsensor`/`NXactuator`/`NXcollection` per module and one `NXlog` per
  parameter that changed. A parameter whose value never changed in the
  exported range is a plain field instead, and a changing string parameter
  (such as the status text) is left out, since an `NXlog` holds numbers.

  The whole history is read into memory and handed to the shared Python
  interpreter, so a large export is slow and holds up the other Python work
  (SECoP check, ophyd class generation) while it runs.
  """

  alias SecantService.SecNodes
  alias SecantService.SecNodes.Reading
  alias SecantService.SecNodes.Reading.Storage
  alias SecantService.SecNodes.SecNode

  require Logger

  # Timestamps and double values cross to Python as packed native float64
  # (read with `np.frombuffer`), everything else as JSON. Elixir strings would
  # otherwise arrive as Python `bytes`, and long lists are slow to convert.
  @python """
  import json
  import numpy as np
  from secop_to_nexus import nexus_bytes

  logs = {}
  for module, parameter, timestamps, encoding, values in series:
      values = (
          np.frombuffer(values, dtype=np.float64)
          if encoding == b"float64"
          else json.loads(values)
      )
      logs.setdefault(module.decode(), {})[parameter.decode()] = (
          np.frombuffer(timestamps, dtype=np.float64),
          values,
      )

  nexus_bytes(describe, logs)
  """

  @doc """
  Returns the NeXus file of `node` as a binary.

  `node` needs its modules and their parameters loaded. `time_range` may hold
  `:start_timestamp` and `:end_timestamp` to restrict the exported values.
  """
  @spec node_file(SecNode.t(), map()) :: {:ok, binary()} | {:error, :no_description | :failed}
  def node_file(%SecNode{} = node, time_range \\ %{}) do
    case describe_json(node) do
      nil -> {:error, :no_description}
      describe -> write(describe, series(node, time_range))
    end
  end

  defp describe_json(%SecNode{describe_message_raw: raw}) when is_binary(raw), do: raw
  defp describe_json(%SecNode{describe_message: %{} = message}), do: Jason.encode!(message)
  defp describe_json(_node), do: nil

  defp series(node, time_range) do
    for module <- node.modules,
        parameter <- module.parameters,
        values = read_values(parameter, time_range),
        values != [] do
      {encoding, packed} = pack_values(values, parameter)
      [module.name, parameter.name, pack_timestamps(values), encoding, packed]
    end
  end

  defp read_values(parameter, time_range) do
    SecNodes.readings!(parameter, Map.put(time_range, :order, :asc),
      select: [:timestamp | Reading.value_columns()]
    )
  end

  defp pack_timestamps(values) do
    for %{timestamp: timestamp} <- values, into: <<>> do
      <<unix_seconds(timestamp)::float-64-native>>
    end
  end

  defp unix_seconds(%DateTime{} = timestamp),
    do: DateTime.to_unix(timestamp, :microsecond) / 1_000_000

  # doubles as packed float64 when every value is one, JSON otherwise
  defp pack_values(values, parameter) do
    raw = Enum.map(values, &Storage.raw_value/1)

    if Storage.column(parameter) == :value_float and Enum.all?(raw, &is_number/1) do
      {"float64", for(v <- raw, into: <<>>, do: <<v * 1.0::float-64-native>>)}
    else
      {"json", Jason.encode!(raw)}
    end
  end

  defp write(describe, series) do
    null = File.open!("/dev/null", [:write])

    try do
      {result, _globals} =
        Pythonx.eval(@python, %{"describe" => describe, "series" => series},
          stdout_device: null,
          stderr_device: null
        )

      {:ok, Pythonx.decode(result)}
    rescue
      e in Pythonx.Error ->
        Logger.error("NeXus export failed: #{Exception.message(e)}")
        {:error, :failed}
    after
      File.close(null)
    end
  end
end
