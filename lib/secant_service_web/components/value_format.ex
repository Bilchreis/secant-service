defmodule SecantServiceWeb.ValueFormat do
  @moduledoc """
  Pure helpers that turn SECoP values and datainfo into short display
  strings. Shared by the live dashboard and the data browser.
  """

  @numeric ["double", "int", "scaled"]

  @doc "Formats a number the way the dashboard shows it (no unit)."
  def number(nil), do: "—"
  def number(val) when is_integer(val), do: Integer.to_string(val)
  def number(val) when val == 0.0, do: "0.0"

  def number(val) when is_float(val) do
    if abs(val) >= 100_000 or abs(val) < 0.001 do
      :io_lib.format("~.3e", [val]) |> to_string()
    else
      :io_lib.format("~.6f", [val])
      |> to_string()
      |> String.replace(~r/0+$/, "")
      |> String.replace(~r/\.$/, ".0")
    end
  end

  def number(val), do: to_string(val)

  def unit(%{"unit" => unit}) when is_binary(unit), do: unit
  def unit(_), do: ""

  def numeric?(%{"type" => type}), do: type in @numeric
  def numeric?(_), do: false

  def numeric_array?(%{"type" => "array", "members" => %{"type" => type}}), do: type in @numeric
  def numeric_array?(_), do: false

  @doc "Name of an enum member for a raw integer value."
  def enum_name(raw, %{"members" => members}) when is_map(members) do
    case Enum.find(members, fn {_name, val} -> val == raw end) do
      {name, _} -> name
      nil -> to_string(raw)
    end
  end

  def enum_name(raw, _), do: to_string(raw)

  @doc "One-line rendering of any value, used in compact places."
  def short(nil, _datainfo), do: "—"

  def short(raw, %{"type" => type} = datainfo) when type in @numeric do
    String.trim("#{number(raw)} #{unit(datainfo)}")
  end

  def short(raw, %{"type" => "enum"} = datainfo), do: enum_name(raw, datainfo)
  def short(raw, %{"type" => "bool"}), do: to_string(raw)
  def short(raw, %{"type" => "string"}) when is_binary(raw), do: raw

  def short(raw, %{"type" => "array"} = datainfo) when is_list(raw) do
    if length(raw) <= 6 do
      "[" <> Enum.map_join(raw, ", ", &short(&1, datainfo["members"])) <> "]"
    else
      "array · #{length(raw)} items"
    end
  end

  def short(raw, %{"type" => "tuple", "members" => members}) when is_list(raw) do
    "(" <>
      (raw
       |> Enum.zip(members)
       |> Enum.map_join(", ", fn {v, info} -> short(v, info) end)) <> ")"
  end

  def short(raw, %{"type" => "struct", "members" => members}) when is_map(raw) do
    "{" <>
      Enum.map_join(members, ", ", fn {name, info} ->
        "#{name}: #{short(member(raw, name), info)}"
      end) <>
      "}"
  end

  def short(raw, _), do: SecantService.Util.short_inspect(raw, 80)

  @doc "Reads a struct member regardless of whether keys are atoms or strings."
  def member(value, name) when is_map(value) do
    case Map.fetch(value, name) do
      {:ok, v} ->
        v

      :error ->
        Enum.find_value(value, fn {k, v} -> if to_string(k) == name, do: v end)
    end
  end

  def member(_, _), do: nil

  @doc "Short type label, e.g. `double`, `array<double>`, `struct{6}`."
  def type_label(%{"type" => "array", "members" => members}), do: "array<#{type_label(members)}>"

  def type_label(%{"type" => "struct", "members" => m}) when is_map(m),
    do: "struct{#{map_size(m)}}"

  def type_label(%{"type" => "tuple", "members" => m}) when is_list(m), do: "tuple(#{length(m)})"
  def type_label(%{"type" => type}), do: type
  def type_label(_), do: "?"

  @doc "Allowed range from datainfo, or nil."
  def limits(%{"type" => type} = datainfo) when type in @numeric do
    case {datainfo["min"], datainfo["max"]} do
      {nil, nil} -> nil
      {min, nil} -> "≥ #{number(min)}"
      {nil, max} -> "≤ #{number(max)}"
      {min, max} -> "#{number(min)} … #{number(max)}"
    end
  end

  def limits(%{"type" => "array"} = datainfo) do
    case {datainfo["minlen"], datainfo["maxlen"]} do
      {nil, nil} -> nil
      {min, max} -> "#{min || 0} … #{max} items"
    end
  end

  def limits(_), do: nil

  @doc """
  SVG polyline points for a numeric array, downsampled to at most `max_points`
  by keeping each bucket's extreme value so peaks stay visible.
  Returns `{points, min, max}`.
  """
  def spectrum(values, width, height, max_points \\ 240) when is_list(values) do
    nums = Enum.filter(values, &is_number/1)

    case nums do
      [] ->
        {"", nil, nil}

      _ ->
        {lo, hi} = Enum.min_max(nums)
        span = if hi == lo, do: 1.0, else: hi - lo
        n = length(nums)
        bucket = max(1, ceil(n / max_points))

        sampled =
          nums
          |> Enum.chunk_every(bucket)
          |> Enum.map(fn chunk -> Enum.max_by(chunk, fn v -> abs(v - lo) end) end)

        count = max(length(sampled) - 1, 1)

        points =
          sampled
          |> Enum.with_index()
          |> Enum.map_join(" ", fn {v, i} ->
            x = i / count * width
            y = height - 2 - (v - lo) / span * (height - 4)
            "#{Float.round(x * 1.0, 1)},#{Float.round(y * 1.0, 1)}"
          end)

        {points, lo, hi}
    end
  end
end
