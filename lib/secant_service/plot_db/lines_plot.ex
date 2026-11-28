defmodule SecantService.PlotDB.LinesPlot do
  @moduledoc """
  A custom module plot of number traces (`SecantService.PlotDB.Trace`) on
  one panel, with up to two y-axes. `axes` names them; an axis without a
  name or unit takes the unit of its first trace.
  """

  alias SecantService.PlotDB.Trace

  defstruct axes: [], traces: []

  @type axis :: %{optional(:name) => String.t() | nil, optional(:unit) => String.t() | nil}

  @type t :: %__MODULE__{axes: [axis()], traces: [Trace.t()]}
end
