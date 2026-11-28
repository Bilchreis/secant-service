defmodule SecantService.PlotDB.Trace do
  @moduledoc """
  One line of a custom lines plot (`SecantService.PlotDB.LinesPlot`): a
  number in the readings of one of the module's parameters.

    * `path` runs through struct fields (`["composition"]`).
    * `pick` chooses an element when the path ends at a numeric array of at
      most 100 elements: `{:index, k}`, `:each` (one trace per element), or
      `{:match, %LabelSource{}, x}` (the element whose label value equals
      `x`, e.g. the mass 28).
    * `label` is fixed text or a `SecantService.PlotDB.LabelSource`.
  """

  alias SecantService.PlotDB.LabelSource

  @enforce_keys [:param]
  defstruct param: nil,
            path: [],
            pick: nil,
            label: nil,
            setpoint?: false,
            hidden?: false,
            axis: 0

  @type pick ::
          nil | {:index, non_neg_integer()} | :each | {:match, LabelSource.t(), number()}

  @type t :: %__MODULE__{
          param: String.t(),
          path: [String.t()],
          pick: pick(),
          label: nil | String.t() | LabelSource.t(),
          setpoint?: boolean(),
          hidden?: boolean(),
          axis: 0 | 1
        }

  @doc """
  The number at `path` (struct fields) in a reading `value`, and at `index`
  of the array there when `index` is not nil. nil for anything that is not a
  number. Never raises: readings come from the node, live with atom keys for
  described struct members, stored with string keys.
  """
  def extract(value, path, index \\ nil)

  def extract(value, [], nil), do: number(value)

  def extract(value, [], index) when is_list(value) and is_integer(index) and index >= 0,
    do: value |> Enum.at(index) |> number()

  def extract(_value, [], _index), do: nil

  def extract(value, [key | rest], index) when is_map(value) do
    case field(value, key) do
      {:ok, inner} -> extract(inner, rest, index)
      :error -> nil
    end
  end

  def extract(_value, _path, _index), do: nil

  @doc """
  The value at `path` (struct fields) in a reading, whatever its type, or
  nil. Never raises.
  """
  def at_path(value, []), do: value

  def at_path(value, [key | rest]) when is_map(value) do
    case field(value, key) do
      {:ok, inner} -> at_path(inner, rest)
      :error -> nil
    end
  end

  def at_path(_value, _path), do: nil

  # the string key, or a key whose string form equals it (an atom key of a
  # live reading), creating no atoms
  defp field(map, key) do
    case Map.fetch(map, key) do
      {:ok, _} = found ->
        found

      :error ->
        Enum.find_value(map, :error, fn {k, v} ->
          if is_atom(k) and Atom.to_string(k) == key, do: {:ok, v}
        end)
    end
  end

  defp number(x) when is_number(x), do: x
  defp number(_), do: nil
end
