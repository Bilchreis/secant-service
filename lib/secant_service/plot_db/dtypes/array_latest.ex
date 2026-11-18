defmodule SecantService.PlotDB.DTypes.ArrayLatest do
  @moduledoc """
  Long 1-D numeric arrays (spectra and the like, longer than the time ×
  index heatmap can carry): only the latest reading, drawn as value over
  array index. Each new reading replaces the line.

  Readings with more than `@max_points` elements are reduced to the min and
  max of equal chunks, so narrow peaks survive.
  """

  alias SecantService.PlotDB.DTypes.ArrayHeatmap
  alias SecantService.SecNodes.Parameter
  alias SecantService.SecNodes.ParameterValue

  @max_points 4000
  # how many readings the time slider can step through (the most recent ones)
  @max_times 20_000

  @doc "Numeric 1-D arrays are the only ones this plot handles."
  def numeric_array?(%Parameter{datainfo: datainfo}), do: ArrayHeatmap.supported_type?(datainfo)
  def numeric_array?(_), do: false

  @doc "Latest stored reading of `param` as `{list, ms}`, or nil."
  def fetch_latest(param) do
    ParameterValue.get_resource_module(param)
    |> Ash.Query.for_read(:for_parameter, %{parameter_id: param.id, limit: 1, order: :desc})
    |> Ash.read_first()
    |> case do
      {:ok, nil} ->
        nil

      {:ok, record} ->
        case ParameterValue.get_raw_value(record, param) do
          list when is_list(list) -> {list, DateTime.to_unix(record.timestamp, :millisecond)}
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end

  @doc """
  Reading of `param` at `ms` (or the last one before it) as `{list, ms}`, or
  nil. Timestamps are stored in microseconds; the browser only has ms.
  """
  def fetch_at(param, ms) when is_integer(ms) do
    until = ms |> DateTime.from_unix!(:millisecond) |> DateTime.add(999, :microsecond)

    ParameterValue.get_resource_module(param)
    |> Ash.Query.for_read(:for_parameter, %{
      parameter_id: param.id,
      end_timestamp: until,
      limit: 1,
      order: :desc
    })
    |> Ash.read_first()
    |> case do
      {:ok, nil} ->
        nil

      {:ok, record} ->
        case ParameterValue.get_raw_value(record, param) do
          list when is_list(list) -> {list, DateTime.to_unix(record.timestamp, :millisecond)}
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end

  @doc "Times (ms, ascending) of the most recent `@max_times` readings, for the slider."
  def reading_times(param) do
    ParameterValue.get_resource_module(param)
    |> Ash.Query.for_read(:for_parameter, %{
      parameter_id: param.id,
      limit: @max_times,
      order: :desc
    })
    |> Ash.Query.select([:timestamp])
    |> Ash.read()
    |> case do
      {:ok, records} ->
        records |> Enum.map(&DateTime.to_unix(&1.timestamp, :millisecond)) |> Enum.reverse()

      {:error, _} ->
        []
    end
  end

  @doc "Snapshot payload for the browser: one reading, reduced for drawing."
  def snapshot({arr, ts}) do
    arr |> info(ts, nil) |> Map.delete(:unit) |> Map.put(:data, points(arr))
  end

  @doc "Plot map for `param`, starting from its latest reading (or nothing yet)."
  def plot(param, latest) do
    {arr, ts} = latest || {[], nil}

    option =
      arr
      |> option(ts, param)
      |> Map.put(:_arrayTimes, reading_times(param))

    %{
      plottable: true,
      plot_available: true,
      plot_type: :array_latest,
      option: option,
      _array_param: param.name
    }
  end

  def option(arr, ts, param) do
    unit = ArrayHeatmap.unit(param.datainfo)

    %{
      animation: false,
      backgroundColor: "transparent",
      grid: %{top: 28, bottom: 44, left: 76, right: 24},
      xAxis: %{
        type: "value",
        name: "index",
        nameLocation: "middle",
        nameGap: 26,
        min: 0,
        max: max(length(arr) - 1, 1),
        minInterval: 1
      },
      yAxis: %{
        type: "value",
        scale: true,
        name: if(unit, do: "#{param.name} (#{unit})", else: param.name),
        nameLocation: "middle",
        nameGap: 56,
        nameRotate: 90
      },
      tooltip: %{trigger: "axis"},
      series: [
        %{
          type: "line",
          name: param.name,
          showSymbol: false,
          lineStyle: %{width: 1.25},
          data: points(arr)
        }
      ],
      _arrayLatest: info(arr, ts, unit)
    }
  end

  @doc "Live update: the newest reading of a batch replaces the line."
  def trace_updates(%{_array_param: name}, datapoints, name) do
    case List.last(datapoints) do
      {arr, ts} when is_list(arr) ->
        %{snapshot: snapshot({arr, ts})}

      _ ->
        %{seriesUpdates: []}
    end
  end

  def trace_updates(_plot, _datapoints, _other_param), do: %{seriesUpdates: []}

  defp info(arr, ts, unit) do
    n = length(arr)
    %{t: ts, n: n, shown: min(n, @max_points), unit: unit}
  end

  @doc """
  `[[index, value], ...]`; above `@max_points` elements the min and max of
  each of `@max_points / 2` chunks, in index order.
  """
  def points(arr) when length(arr) <= @max_points do
    arr |> Enum.with_index() |> Enum.map(fn {v, i} -> [i, v] end)
  end

  def points(arr) do
    size = ceil(length(arr) / div(@max_points, 2))

    arr
    |> Enum.with_index()
    |> Enum.reject(fn {v, _} -> not is_number(v) end)
    |> Enum.chunk_every(size)
    |> Enum.flat_map(fn chunk ->
      lo = Enum.min_by(chunk, &elem(&1, 0))
      hi = Enum.max_by(chunk, &elem(&1, 0))

      [lo, hi]
      |> Enum.uniq()
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.map(fn {v, i} -> [i, v] end)
    end)
  end
end
