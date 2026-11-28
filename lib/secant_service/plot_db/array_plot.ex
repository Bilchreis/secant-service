defmodule SecantService.PlotDB.ArrayPlot do
  @moduledoc """
  A custom module plot of the module's `value` as the generic array plot
  draws it (time × index heatmap, or the latest reading of a long array),
  with its index labelled from another parameter (`labels`, a
  `SecantService.PlotDB.LabelSource` that names a parameter), e.g. a mass
  spectrum's indexes as `m/z 28` from `_mass`, and an optional index axis
  name.
  """

  alias SecantService.PlotDB.LabelSource

  defstruct labels: nil, axis_name: nil

  @type t :: %__MODULE__{labels: LabelSource.t() | nil, axis_name: String.t() | nil}
end
