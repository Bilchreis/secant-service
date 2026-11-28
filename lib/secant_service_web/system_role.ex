defmodule SecantServiceWeb.SystemRole do
  @moduledoc """
  One role of a system definition (`SecantServiceWeb.SystemDefinition`): what
  a module bound in that role must have, and the custom card and module plot
  it gets. Every callback is required; `card/0` and `plot/0` return nil for
  "none", and the module then keeps the generic one.

  ## Card

  `card/0` returns `%{body: fun, shown_parameters: names}`:

    * `body` is a function component. Its assigns are `module`, `node`,
      `node_id_str`, `binding`, `node_state`, `status` and `location`. The
      dashboard renders it inside the shared card chrome (name, class,
      selection, status tint, parameters button).
    * `shown_parameters` lists every parameter the body displays. Only those
      get live updates: a parameter shown but not listed keeps its first
      value.

  A body must not assume the dashboard (system views will reuse it): build
  ids from the `location` assign, e.g. through
  `SecantServiceWeb.Systems.Components`, and show each parameter at most
  once, since two displays of one parameter at one location share an id.

  ## Plot

  `plot/0` returns a `SecantService.PlotDB.LinesPlot`, a
  `SecantService.PlotDB.ArrayPlot` or nil. It replaces the generic module
  plot of a matched module that has a `value`.
  """

  @type card :: %{
          body: (map() -> Phoenix.LiveView.Rendered.t()),
          shown_parameters: [String.t()]
        }

  @doc "Parameters a module must have to match this role."
  @callback required_parameters() :: [String.t()]

  @doc "The custom card, or nil for the generic one."
  @callback card() :: card() | nil

  @doc "The custom module plot, or nil for the generic one."
  @callback plot() ::
              SecantService.PlotDB.LinesPlot.t() | SecantService.PlotDB.ArrayPlot.t() | nil
end
