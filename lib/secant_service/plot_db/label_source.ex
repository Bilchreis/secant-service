defmodule SecantService.PlotDB.LabelSource do
  @moduledoc """
  Where a label comes from: a path in the latest reading of a parameter of
  the module (`param`, nil for the trace's own parameter), written through an
  optional template whose `{}` takes the value, e.g. `"m/z {}"`.

  For per-element traces and array plots the path leads to an array, read at
  the element's index.
  """

  defstruct param: nil, path: [], template: nil

  @type t :: %__MODULE__{
          param: String.t() | nil,
          path: [String.t()],
          template: String.t() | nil
        }

  @doc """
  The text of a label value: a non-empty string as it is, a whole number
  without a fraction (28.0 → "28"), any other number in its shortest form;
  put into the template's `{}` when there is one. nil for anything else.
  Never raises.
  """
  def text(value, template \\ nil) do
    case raw_text(value) do
      nil -> nil
      text when is_binary(template) -> String.replace(template, "{}", text)
      text -> text
    end
  end

  defp raw_text(value) when is_binary(value) and value != "", do: value
  defp raw_text(value) when is_integer(value), do: Integer.to_string(value)

  defp raw_text(value) when is_float(value) do
    if value == Float.round(value) and abs(value) < 1.0e15,
      do: value |> trunc() |> Integer.to_string(),
      else: :erlang.float_to_binary(value, [:short])
  end

  defp raw_text(_value), do: nil
end
