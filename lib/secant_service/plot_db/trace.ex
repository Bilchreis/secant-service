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
end
