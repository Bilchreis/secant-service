defmodule SecantService.PlotDB.Traces do
  @moduledoc """
  Resolves a role's custom plot (`SecantService.PlotDB.LinesPlot`,
  `SecantService.PlotDB.ArrayPlot`) against a module: which traces it can
  draw, their elements, stable series names and labels.

    * `drawable?/2` reads the description only and never raises, so it can
      run while rendering.
    * `resolve/2` also reads the latest value of the parameters it needs
      (undeclared array lengths, `:each` counts, `:match` lookups, label
      sources), once per parameter, before any window is fetched. It runs in
      the plot's async load.

  Element traces read arrays of at most #{100} elements: longer arrays would
  have their whole readings fetched for every window.
  """

  alias SecantService.PlotDB.ArrayPlot
  alias SecantService.PlotDB.DTypes.ArrayLatest
  alias SecantService.PlotDB.DTypes.Scalar
  alias SecantService.PlotDB.History
  alias SecantService.PlotDB.History.Channels
  alias SecantService.PlotDB.LabelSource
  alias SecantService.PlotDB.LinesPlot
  alias SecantService.PlotDB.Trace
  alias SecantService.SecNodes
  alias SecantService.SecNodes.Reading.Storage

  @max_elements 100
  @max_traces 16

  def max_traces, do: @max_traces

  @type entry :: %{
          param: map(),
          path: [String.t()],
          index: non_neg_integer() | nil,
          series: String.t(),
          label: String.t() | nil,
          unit: String.t() | nil,
          setpoint?: boolean(),
          hidden?: boolean(),
          axis: 0 | 1
        }

  @doc """
  Whether `spec` can draw anything on `module`, from the description alone.
  Never raises: malformed datainfo gives false.
  """
  def drawable?(module, %LinesPlot{traces: traces}) when is_list(traces) do
    params = params(module)
    Enum.any?(traces, &drawable_trace?(Map.get(params, trace_param(&1)), &1))
  end

  def drawable?(module, %ArrayPlot{}) do
    case Map.get(params(module), "value") do
      nil -> false
      value -> ArrayLatest.numeric_array?(value)
    end
  end

  def drawable?(_module, _spec), do: false

  @doc """
  The traces of a lines plot on `module`, as entries (see `t:entry/0`), at
  most #{@max_traces}, or `:no_traces`.
  """
  def resolve(module, %LinesPlot{traces: traces}) when is_list(traces) do
    params = params(module)

    candidates =
      for %Trace{} = trace <- traces,
          param = Map.get(params, trace.param),
          drawable_trace?(param, trace),
          do: {trace, param}

    latest = latest_values(candidates, params)

    candidates
    |> Enum.flat_map(fn {trace, param} -> expand(trace, param, latest) end)
    |> Enum.uniq_by(& &1.series)
    |> Enum.take(@max_traces)
    |> case do
      [] -> :no_traces
      entries -> entries
    end
  end

  def resolve(_module, _spec), do: :no_traces

  @doc """
  The index labels of an array plot on `module`: the label texts of the
  first `limit` entries of its label source's latest reading, nil where an
  entry gives none. `[]` without a usable source.
  """
  def index_labels(module, %ArrayPlot{labels: %LabelSource{param: name} = source}, limit)
      when is_binary(name) do
    case Map.get(params(module), name) do
      nil ->
        []

      param ->
        case param |> latest_value() |> Trace.at_path(source.path) do
          list when is_list(list) and length(list) <= limit ->
            Enum.map(list, &LabelSource.text(&1, source.template))

          _ ->
            []
        end
    end
  end

  def index_labels(_module, _spec, _limit), do: []

  @doc "The latest stored value of `param`, of any type, or nil."
  def latest_value(%{id: id}) do
    case SecNodes.latest_reading(id) do
      {:ok, %{} = record} -> Storage.raw_value(record)
      _ -> nil
    end
  end

  def latest_value(_param), do: nil

  # ---------------------------------------------------------------------------

  defp params(%{parameters: parameters}) when is_list(parameters),
    do: Map.new(parameters, &{&1.name, &1})

  defp params(_module), do: %{}

  defp trace_param(%Trace{param: param}), do: param
  defp trace_param(_), do: nil

  # the declared type gives a number at the trace's path (an element of a
  # numeric array of at most 100 elements when it picks one), and History
  # can thin the parameter
  defp drawable_trace?(nil, _trace), do: false

  defp drawable_trace?(param, %Trace{path: path, pick: pick}) when is_list(path) do
    History.thinnable?(param) and
      case datainfo_at(param.datainfo, path) do
        {:ok, datainfo} -> drawable_type?(datainfo, pick)
        :error -> false
      end
  end

  defp drawable_trace?(_param, _trace), do: false

  defp drawable_type?(datainfo, nil), do: Scalar.supported_type?(datainfo)

  defp drawable_type?(%{"type" => "array", "members" => members} = datainfo, _pick)
       when is_map(members) do
    Scalar.supported_type?(members) and
      case Channels.declared_length(datainfo) do
        nil -> true
        n -> n <= @max_elements
      end
  end

  defp drawable_type?(_datainfo, _pick), do: false

  # the datainfo at a path of struct fields
  defp datainfo_at(datainfo, []) when is_map(datainfo), do: {:ok, datainfo}

  defp datainfo_at(%{"type" => "struct", "members" => members}, [key | rest])
       when is_map(members) and is_binary(key) do
    case Map.fetch(members, key) do
      {:ok, inner} when is_map(inner) -> datainfo_at(inner, rest)
      _ -> :error
    end
  end

  defp datainfo_at(_datainfo, _path), do: :error

  # The latest value of each parameter the traces need one of, read once
  # each: picks into arrays without a declared length (their length is
  # checked before any window is fetched), `:each` counts, `:match` lookups
  # and label sources.
  defp latest_values(candidates, params) do
    candidates
    |> Enum.flat_map(fn {trace, param} -> needs_latest(trace, param) end)
    |> Enum.uniq()
    |> Map.new(fn name -> {name, latest_value(Map.get(params, name))} end)
  end

  defp needs_latest(trace, param) do
    # an undeclared array's length decides whether it is drawn (and how
    # many `:each` traces it gives)
    own =
      if trace.pick != nil and undeclared_array?(param, trace.path),
        do: [param.name],
        else: []

    match =
      case trace.pick do
        {:match, %LabelSource{} = source, _} -> [source.param || param.name]
        _ -> []
      end

    label =
      case trace.label do
        %LabelSource{} = source -> [source.param || param.name]
        _ -> []
      end

    own ++ match ++ label
  end

  defp undeclared_array?(param, path) do
    case datainfo_at(param.datainfo, path) do
      {:ok, datainfo} -> Channels.declared_length(datainfo) == nil
      :error -> false
    end
  end

  defp expand(%Trace{pick: nil} = trace, param, latest),
    do: [entry(trace, param, nil, latest)]

  defp expand(%Trace{} = trace, param, latest) do
    if too_long?(trace, param, latest) do
      []
    else
      case trace.pick do
        {:index, k} when is_integer(k) and k >= 0 and k < @max_elements ->
          [entry(trace, param, k, latest)]

        :each ->
          for k <- each_indexes(trace, param, latest), do: entry(trace, param, k, latest)

        {:match, %LabelSource{} = source, x} when is_number(x) ->
          case match_index(source, param, x, latest) do
            nil -> []
            k -> [entry(trace, param, k, latest)]
          end

        _ ->
          []
      end
    end
  end

  # an array read longer than the plots carry per element
  defp too_long?(trace, param, latest) do
    case latest |> Map.get(param.name) |> Trace.at_path(trace.path) do
      list when is_list(list) -> length(list) > @max_elements
      _ -> false
    end
  end

  defp each_indexes(trace, param, latest) do
    declared =
      case datainfo_at(param.datainfo, trace.path) do
        {:ok, datainfo} -> Channels.declared_length(datainfo)
        :error -> nil
      end

    count =
      declared ||
        case latest |> Map.get(param.name) |> Trace.at_path(trace.path) do
          list when is_list(list) -> length(list)
          _ -> 0
        end

    # never more than the plot can draw
    case min(count, @max_traces) do
      0 -> []
      n -> Enum.to_list(0..(n - 1))
    end
  end

  defp match_index(source, param, x, latest) do
    case latest |> Map.get(source.param || param.name) |> Trace.at_path(source.path) do
      list when is_list(list) -> Enum.find_index(list, &(is_number(&1) and &1 == x))
      _ -> nil
    end
  end

  defp entry(trace, param, index, latest) do
    %{
      param: param,
      path: trace.path,
      index: index,
      series: series_name(param.name, trace.path, index),
      label: label(trace.label, param, index, latest),
      unit: unit(param.datainfo, trace.path, index),
      setpoint?: trace.setpoint? == true,
      hidden?: trace.hidden? == true,
      axis: if(trace.axis == 1, do: 1, else: 0)
    }
  end

  @doc """
  A trace's stable series name: the parameter's name for the whole
  parameter (`value`, `target`), else with its path and element, e.g.
  `value.composition[2]` or `value[27]`.
  """
  def series_name(name, path, index) do
    Enum.map_join([name | path], ".", & &1) <> if(index, do: "[#{index}]", else: "")
  end

  defp label(text, _param, _index, _latest) when is_binary(text) and text != "", do: text

  defp label(%LabelSource{} = source, param, index, latest) do
    value = latest |> Map.get(source.param || param.name) |> Trace.at_path(source.path)

    value =
      case {value, index} do
        {list, i} when is_list(list) and is_integer(i) -> Enum.at(list, i)
        {_, i} when is_integer(i) -> nil
        {v, nil} -> v
      end

    LabelSource.text(value, source.template)
  end

  defp label(_label, _param, _index, _latest), do: nil

  # the unit along the trace's path: a struct member's, or an array's
  # elements'
  defp unit(datainfo, path, index) do
    case datainfo_at(datainfo, path) do
      {:ok, %{"members" => %{} = members}} when is_integer(index) -> unit_of(members)
      {:ok, datainfo} -> unit_of(datainfo)
      :error -> nil
    end
  end

  defp unit_of(%{"unit" => unit}) when is_binary(unit) and unit != "", do: unit
  defp unit_of(_), do: nil
end
