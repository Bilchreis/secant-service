defmodule SecantService.PlotDB.History.Channels do
  @moduledoc """
  The values a plot draws from a parameter's readings, as a list of channels.

  `SecantService.PlotDB.History` thins out long recordings by keeping, per
  time bucket, the readings that matter for each channel: its lowest and
  highest value, or the first reading of each state. Any plottable type
  breaks down into channels:

    * `double`, `int`, `scaled`: one `:number` channel
    * `enum`: one `:state` channel
    * numeric `array`: one `:number_array` channel, one value per element
    * `struct`: the channels of its plottable fields, read from the JSON
      value, nested structs included

  How a channel picks its readings is its *picker*, chosen by the SECoP type
  of its values (for an array, of its elements) and set in the config:

      config :secant_service, SecantService.PlotDB.History,
        pickers: %{"double" => :extremes, "enum" => :each_state}

    * `:extremes`: the readings with the lowest and highest value
    * `:each_state`: the first reading of each value that occurs
    * `:first_last`: nothing beyond the first and last reading, which every
      bucket keeps anyway

  Arrays with more than `wide_array/0` elements are picked by the lowest and
  highest value of the whole array, not of every element, so that a wide
  array keeps a few readings per bucket instead of a few per element.
  """

  alias SecantService.SecNodes.Reading.Storage

  @number_types ["double", "int", "scaled"]

  @default_pickers %{
    "double" => :extremes,
    "scaled" => :extremes,
    "int" => :extremes,
    "enum" => :each_state
  }

  @pickers [:extremes, :each_state, :first_last]

  # arrays wider than this are picked as a whole, not per element
  @wide_array 16
  # elements assumed for an array whose datainfo has no maxlen
  @default_array_len 16
  # longest declared array length a plot draws rows or lines for
  @max_declared_len 1_000
  # values assumed for an int picked by :each_state
  @default_states 8

  @type picker :: :extremes | :each_state | :first_last

  @type t :: %__MODULE__{
          kind: :number | :state | :number_array,
          type: String.t(),
          source: {:column, atom} | {:json, [String.t()]},
          picker: picker,
          elements: pos_integer,
          per_element?: boolean,
          states: pos_integer
        }

  defstruct [:kind, :type, :source, :picker, elements: 1, per_element?: false, states: 1]

  @doc "The channels of a datainfo; empty when nothing of it is plotted."
  @spec from_datainfo(map | nil) :: [t]
  def from_datainfo(%{"type" => "struct"} = datainfo), do: struct_channels(datainfo, ["value"])

  def from_datainfo(%{"type" => _} = datainfo),
    do: channels(datainfo, {:column, Storage.column(datainfo)})

  def from_datainfo(_datainfo), do: []

  @doc """
  The length an array's datainfo declares (`maxlen`, else `minlen`), or nil.
  The datainfo comes from the node, so only a positive integer counts. With
  `max:`, a longer declared length is ignored too: use that where the length
  decides how much is drawn (one row or line per element), so a bogus huge
  one can't make the browser build that many; the readings' own length still
  counts there.
  """
  def declared_length(datainfo, opts \\ []) do
    max = Keyword.get(opts, :max)

    Enum.find(
      [datainfo["maxlen"], datainfo["minlen"]],
      &(is_integer(&1) and &1 > 0 and (max == nil or &1 <= max))
    )
  end

  @doc "Longest declared array length a plot draws rows or lines for."
  def max_drawn_length, do: @max_declared_len

  @doc "Arrays wider than this are picked as a whole, not per element."
  def wide_array, do: @wide_array

  @doc "How many values a reading adds to the chart: one per element of each channel."
  def points_per_reading(channels),
    do: channels |> Enum.map(& &1.elements) |> Enum.sum() |> max(1)

  @doc """
  The most readings one bucket can keep: its first and last, plus what each
  channel's picker adds.
  """
  def picks_per_bucket(channels), do: 2 + (channels |> Enum.map(&picks/1) |> Enum.sum())

  defp picks(%__MODULE__{picker: :first_last}), do: 0
  defp picks(%__MODULE__{picker: :extremes} = c), do: 2 * groups(c)
  defp picks(%__MODULE__{picker: :each_state} = c), do: c.states * groups(c)

  defp groups(%__MODULE__{per_element?: true, elements: n}), do: n
  defp groups(_channel), do: 1

  # -- breaking a datainfo down ------------------------------------------------

  defp channels(%{"type" => type} = datainfo, source) when type in @number_types do
    [channel(:number, type, source, datainfo)]
  end

  defp channels(%{"type" => "enum"} = datainfo, source) do
    [channel(:state, "enum", source, datainfo)]
  end

  defp channels(%{"type" => "array", "members" => %{"type" => member}} = datainfo, source)
       when member in @number_types do
    elements = declared_length(datainfo) || @default_array_len

    [
      %{
        channel(:number_array, member, source, datainfo["members"])
        | elements: elements,
          per_element?: elements <= @wide_array
      }
    ]
  end

  defp channels(%{"type" => "struct"} = datainfo, {:json, path}),
    do: struct_channels(datainfo, path)

  defp channels(_datainfo, _source), do: []

  defp struct_channels(%{"members" => members}, path) when is_map(members) do
    members
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {name, sub} -> channels(sub, {:json, path ++ [name]}) end)
  end

  defp struct_channels(_datainfo, _path), do: []

  defp channel(kind, type, source, datainfo) do
    picker = picker(type)

    %__MODULE__{
      kind: kind,
      type: type,
      source: source,
      picker: picker,
      states: states(picker, datainfo)
    }
  end

  defp states(:each_state, %{"members" => members}) when is_map(members),
    do: max(map_size(members), 1)

  defp states(:each_state, _datainfo), do: @default_states
  defp states(_picker, _datainfo), do: 1

  @doc "The picker for values of a SECoP type, from the config or the defaults."
  def picker(type) do
    configured =
      :secant_service
      |> Application.get_env(SecantService.PlotDB.History, [])
      |> Keyword.get(:pickers, %{})

    case Map.get(configured, type) || Map.get(@default_pickers, type, :extremes) do
      picker when picker in @pickers ->
        picker

      other ->
        raise ArgumentError,
              "unknown history picker #{inspect(other)} for #{type}, expected one of #{inspect(@pickers)}"
    end
  end
end
