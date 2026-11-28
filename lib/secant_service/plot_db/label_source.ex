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
end
