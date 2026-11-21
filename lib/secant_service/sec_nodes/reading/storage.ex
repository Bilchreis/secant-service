defmodule SecantService.SecNodes.Reading.Storage do
  @moduledoc """
  Where a value goes in a `SecantService.SecNodes.Reading`, and how it comes
  back out.

  The parameter's datainfo picks the column. A value that does not fit the
  declared type (a node sending a float for an `int`, say) is not dropped or
  coerced: it is kept as it was sent in `value_json`. Reading a value back
  therefore never needs the datainfo; it is whichever column is set.

  Postgres text and jsonb cannot hold a NUL character. A value containing
  one is stored as its JSON text instead (`%{"type" => ..., "json" => text}`
  in `value_json`), which escapes it as `\\u0000`; qualifiers containing one
  as `%{"_json" => text}`. `raw_value/1` and `qualifiers/1` decode them.
  """

  alias SecantService.SecNodes.{Parameter, Reading}

  require Logger

  @int_types ["int", "scaled", "enum"]
  # columns that can hold a string, so a NUL character
  @string_columns [:value_text, :value_text_array, :value_json]
  @nul_qualifiers "_json"
  @int64 Bitwise.bsl(1, 63)
  # largest integer that still converts to a float
  @max_float_int trunc(1.7976931348623157e308)

  @doc "The column for values of a parameter (or a datainfo)."
  def column(%Parameter{datainfo: datainfo}), do: column(datainfo)
  def column(%{"type" => "double"}), do: :value_float
  def column(%{"type" => type}) when type in @int_types, do: :value_int
  def column(%{"type" => "bool"}), do: :value_bool
  def column(%{"type" => "string"}), do: :value_text

  def column(%{"type" => "array", "members" => %{"type" => member}}) do
    case member do
      "double" -> :value_float_array
      m when m in @int_types -> :value_int_array
      "bool" -> :value_bool_array
      "string" -> :value_text_array
      _ -> :value_json
    end
  end

  def column(_datainfo), do: :value_json

  @doc """
  The row to insert for a value the node sent, or nil for a nil value.
  `timestamp` is the node's `t` (Unix seconds) or a `DateTime`.
  """
  def to_row(nil, _parameter, _timestamp, _qualifiers), do: nil

  def to_row(raw, %Parameter{} = parameter, timestamp, qualifiers) do
    {column, value} = place(raw, parameter.datainfo)

    %{
      parameter_id: parameter.id,
      timestamp: to_datetime(timestamp),
      qualifiers: drop_t(qualifiers || %{})
    }
    |> Map.put(column, value)
  end

  @doc "The value of a reading, as the node sent it."
  def raw_value(%Reading{} = reading) do
    case Enum.find_value(Reading.value_columns(), &value_of(reading, &1)) do
      {:json, %{"type" => _, "json" => text}} when is_binary(text) -> Jason.decode!(text)
      {:json, %{"value" => value}} -> value
      {:json, value} -> value
      {_column, value} -> value
      nil -> nil
    end
  end

  @doc "The qualifiers of a reading, as the node sent them (without `t`)."
  def qualifiers(%Reading{qualifiers: %{@nul_qualifiers => text}}) when is_binary(text),
    do: Jason.decode!(text)

  def qualifiers(%Reading{qualifiers: qualifiers}), do: qualifiers

  @doc """
  What makes two readings the same reading: timestamp, column and value, as
  `{timestamp, column, value}`. Works on a row from `to_row/4` and on a
  stored `Reading`; compare two with `same?/2`.
  """
  def fingerprint(%Reading{} = reading) do
    case Enum.find_value(Reading.value_columns(), &value_of(reading, &1)) do
      {:json, value} -> {reading.timestamp, :value_json, value}
      {column, value} -> {reading.timestamp, column, value}
      nil -> {reading.timestamp, nil, nil}
    end
  end

  def fingerprint(%{timestamp: timestamp} = row) do
    case Enum.find(Reading.value_columns(), &Map.has_key?(row, &1)) do
      nil -> {timestamp, nil, nil}
      column -> {timestamp, column, Map.fetch!(row, column)}
    end
  end

  @doc """
  Whether two fingerprints are the same reading. JSON values are compared
  after a JSON round trip (the client decodes struct keys as atoms, the
  database returns strings), and only when the timestamps already match.
  """
  def same?({ts, :value_json, a}, {ts, :value_json, b}),
    do: a == b or normalise(a) == normalise(b)

  def same?({ts, column, a}, {ts, column, b}), do: a == b
  def same?(_a, _b), do: false

  defp normalise(value), do: value |> Jason.encode!() |> Jason.decode!()

  @doc "`{values, timestamps_ms}` of a list of readings, for the plots."
  def value_timestamp_lists(readings) do
    {Enum.map(readings, &raw_value/1),
     Enum.map(readings, &DateTime.to_unix(&1.timestamp, :millisecond))}
  end

  @doc "A reading formatted for the history table, with unit."
  def display_value(%Reading{} = reading, %Parameter{datainfo: datainfo}) do
    raw = raw_value(reading)
    unit = datainfo["unit"] || ""

    case {datainfo["type"], raw} do
      {"double", value} when is_number(value) ->
        datainfo |> fmtstr() |> ExPrintf.sprintf([value * 1.0]) |> with_unit(unit)

      {"scaled", value} when is_number(value) ->
        scaled = value * (datainfo["scale"] || 1.0) * 1.0
        datainfo |> fmtstr() |> ExPrintf.sprintf([scaled]) |> with_unit(unit)

      {"enum", value} ->
        enum_name(datainfo["members"], value)

      {"array", values} when is_list(values) ->
        ("[" <> Enum.map_join(values, ", ", &element/1) <> "]") |> with_unit(unit)

      {_type, value} ->
        value |> Jason.encode!() |> with_unit(unit)
    end
  end

  # -- writing -----------------------------------------------------------------

  defp place(raw, datainfo) do
    column = column(datainfo)

    fits? = fits?(column, raw)

    cond do
      (column in @string_columns or not fits?) and nul?(raw) ->
        {:value_json, %{"type" => datainfo["type"], "json" => Jason.encode!(raw)}}

      fits? ->
        {column, cast(column, raw)}

      true ->
        {:value_json, %{"type" => datainfo["type"], "value" => raw}}
    end
  end

  # whether a NUL character is in any string of the value
  defp nul?(v) when is_binary(v), do: :binary.match(v, <<0>>) != :nomatch
  defp nul?(v) when is_list(v), do: Enum.any?(v, &nul?/1)
  defp nul?(v) when is_map(v), do: Enum.any?(v, fn {k, v} -> nul?(k) or nul?(v) end)
  defp nul?(_v), do: false

  defp fits?(:value_float, v), do: float?(v)
  defp fits?(:value_int, v), do: int64?(v)
  defp fits?(:value_bool, v), do: is_boolean(v)
  defp fits?(:value_text, v), do: is_binary(v)
  defp fits?(:value_float_array, v), do: is_list(v) and Enum.all?(v, &float?/1)
  defp fits?(:value_int_array, v), do: is_list(v) and Enum.all?(v, &int64?/1)
  defp fits?(:value_bool_array, v), do: is_list(v) and Enum.all?(v, &is_boolean/1)
  defp fits?(:value_text_array, v), do: is_list(v) and Enum.all?(v, &is_binary/1)
  defp fits?(:value_json, _v), do: true

  # what a float8 / bigint column can hold; anything else goes to value_json
  defp float?(v), do: is_float(v) or (is_integer(v) and abs(v) <= @max_float_int)
  defp int64?(v), do: is_integer(v) and v >= -@int64 and v < @int64

  defp cast(:value_float, v), do: v * 1.0
  defp cast(:value_float_array, v), do: Enum.map(v, &(&1 * 1.0))
  defp cast(:value_json, v), do: %{"value" => v}
  defp cast(_column, v), do: v

  defp drop_t(qualifiers) when is_map(qualifiers) do
    qualifiers = Map.drop(qualifiers, [:t, "t"])
    if nul?(qualifiers), do: %{@nul_qualifiers => Jason.encode!(qualifiers)}, else: qualifiers
  end

  defp drop_t(qualifiers), do: %{"unexpected" => inspect(qualifiers)}

  defp to_datetime(%DateTime{} = dt), do: dt

  defp to_datetime(unix) when is_number(unix) do
    DateTime.from_unix!(trunc(unix * 1_000_000), :microsecond)
  rescue
    ArgumentError -> fallback_now(unix)
  end

  defp to_datetime(other), do: fallback_now(other)

  defp fallback_now(timestamp) do
    Logger.warning("Invalid timestamp #{inspect(timestamp)}, using the current time")
    DateTime.utc_now()
  end

  # -- reading -----------------------------------------------------------------

  defp value_of(reading, column) do
    case Map.get(reading, column) do
      nil -> nil
      value when column == :value_json -> {:json, value}
      value -> {column, value}
    end
  end

  defp fmtstr(datainfo), do: datainfo["fmtstr"] || "%.6g"

  defp with_unit(text, ""), do: text
  defp with_unit(text, unit), do: "#{text} #{unit}"

  defp element(v) when is_number(v) or is_binary(v), do: to_string(v)
  defp element(v), do: Jason.encode!(v)

  defp enum_name(members, value) when is_map(members) and is_integer(value) do
    case Enum.find(members, fn {_name, v} -> v == value end) do
      {name, _} -> name
      nil -> "unknown_#{value}"
    end
  end

  defp enum_name(_members, value), do: "unknown #{Jason.encode!(value)}"
end
