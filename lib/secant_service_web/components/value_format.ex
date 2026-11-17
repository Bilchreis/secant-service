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

  # Rotating colours for enum members, indexed by rem(code, 20). Neutral hues
  # come first and the status-like ones (green, yellow, orange, red) last, so
  # common codes 0..3 don't read as alarms. Same order as
  # the plot colours in SecantService.PlotDB.DTypes.Enum, so a member has the
  # same colour on cards, in the inspector and in plots.
  @enum_classes [
    "bg-slate-100 text-slate-800 dark:bg-slate-800/50 dark:text-slate-300 border-slate-300 dark:border-slate-700",
    "bg-blue-100 text-blue-800 dark:bg-blue-900/50 dark:text-blue-300 border-blue-300 dark:border-blue-800",
    "bg-teal-100 text-teal-800 dark:bg-teal-900/50 dark:text-teal-300 border-teal-300 dark:border-teal-800",
    "bg-purple-100 text-purple-800 dark:bg-purple-900/50 dark:text-purple-300 border-purple-300 dark:border-purple-800",
    "bg-pink-100 text-pink-800 dark:bg-pink-900/50 dark:text-pink-300 border-pink-300 dark:border-pink-800",
    "bg-cyan-100 text-cyan-800 dark:bg-cyan-900/50 dark:text-cyan-300 border-cyan-300 dark:border-cyan-800",
    "bg-lime-100 text-lime-800 dark:bg-lime-900/50 dark:text-lime-300 border-lime-300 dark:border-lime-800",
    "bg-indigo-100 text-indigo-800 dark:bg-indigo-900/50 dark:text-indigo-300 border-indigo-300 dark:border-indigo-800",
    "bg-fuchsia-100 text-fuchsia-800 dark:bg-fuchsia-900/50 dark:text-fuchsia-300 border-fuchsia-300 dark:border-fuchsia-800",
    "bg-sky-100 text-sky-800 dark:bg-sky-900/50 dark:text-sky-300 border-sky-300 dark:border-sky-800",
    "bg-violet-100 text-violet-800 dark:bg-violet-900/50 dark:text-violet-300 border-violet-300 dark:border-violet-800",
    "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/50 dark:text-emerald-300 border-emerald-300 dark:border-emerald-800",
    "bg-zinc-100 text-zinc-800 dark:bg-zinc-800/50 dark:text-zinc-300 border-zinc-300 dark:border-zinc-700",
    "bg-stone-100 text-stone-800 dark:bg-stone-800/50 dark:text-stone-300 border-stone-300 dark:border-stone-700",
    "bg-green-100 text-green-800 dark:bg-green-900/50 dark:text-green-300 border-green-300 dark:border-green-800",
    "bg-yellow-100 text-yellow-800 dark:bg-yellow-900/50 dark:text-yellow-300 border-yellow-300 dark:border-yellow-800",
    "bg-orange-100 text-orange-800 dark:bg-orange-900/50 dark:text-orange-300 border-orange-300 dark:border-orange-800",
    "bg-amber-100 text-amber-800 dark:bg-amber-900/50 dark:text-amber-300 border-amber-300 dark:border-amber-800",
    "bg-red-100 text-red-800 dark:bg-red-900/50 dark:text-red-300 border-red-300 dark:border-red-800",
    "bg-rose-100 text-rose-800 dark:bg-rose-900/50 dark:text-rose-300 border-rose-300 dark:border-rose-800"
  ]

  @doc "Colour classes (background, text, border) for an enum member code."
  def enum_class(code) when is_integer(code),
    do: Enum.at(@enum_classes, rem(abs(code), length(@enum_classes)))

  def enum_class(_), do: "border-line text-muted"

  def enum?(%{"type" => "enum"}), do: true
  def enum?(_), do: false

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

  @doc "Text with a line-break opportunity after each underscore, for long identifiers."
  def breakable(text) do
    text
    |> to_string()
    |> String.split("_")
    |> Enum.map(&Phoenix.HTML.html_escape/1)
    |> Enum.intersperse({:safe, "_<wbr>"})
  end

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
