defmodule SecantService.PlotDB.DTypePlot do
  @doc "Build one or more ECharts series maps for the given parameter data."
  @callback build_series(
              name :: String.t(),
              ts :: [integer],
              vals :: [term],
              datainfo :: map
            ) :: [map]

  @doc """
  Build a complete ECharts option map for the given series.

  `opts` accepts type-specific overrides:
    - `array_len: integer` (ArrayHeatmap)
    - `y_categories: [String.t()]` (Enum — for multi-param plots like Drivable)
    - `legend_selected: map` (Scalar — hide/show series in legend by default)
  """
  @callback build_option(
              series :: [map],
              datainfo :: map,
              unit :: String.t() | nil,
              mode :: :live | :historical,
              opts :: keyword
            ) :: map

  @doc "Convert a batch of live datapoints into series update payloads for the JS chart hook."
  @callback series_updates(
              option :: map,
              datapoints :: [{term, integer}],
              series_name :: String.t()
            ) :: [map]

  @doc "Return true if this module handles the given datainfo type."
  @callback supported_type?(datainfo :: map) :: boolean

  # Most-specific first: Struct before ArrayHeatmap before Enum before Scalar.
  @registered [
    SecantService.PlotDB.DTypes.Struct,
    SecantService.PlotDB.DTypes.ArrayHeatmap,
    SecantService.PlotDB.DTypes.Enum,
    SecantService.PlotDB.DTypes.Scalar
  ]

  @doc "Return the first registered dtype module that supports `datainfo`, or `nil`."
  def for_datainfo(nil), do: nil

  def for_datainfo(datainfo) do
    Enum.find(@registered, fn mod -> mod.supported_type?(datainfo) end)
  end
end
