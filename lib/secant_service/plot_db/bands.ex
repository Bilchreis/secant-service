defmodule SecantService.PlotDB.Bands do
  @moduledoc """
  Which lines of a historical plot may be drawn as a min/mean/max band, and
  the band payloads the chart hook draws them from.

  A band goes on a number line that is not a setpoint: the value of a
  parameter or module, and a Calibratable's `_value_uncalibrated`. The
  readings come from `SecantService.PlotDB.History` with `envelope: true`;
  this module only decides where they go.
  """

  alias SecantService.PlotDB.DTypes.Scalar

  @doc "Whether a line (see `SecantService.PlotDB.lines/1`) may carry a band."
  def eligible?(%{setpoint?: false, param: %{datainfo: datainfo}}),
    do: Scalar.supported_type?(datainfo)

  def eligible?(_line), do: false

  @doc """
  Whether the first load of a line is read as an envelope: every line that
  may carry a band, in historical plots only.
  """
  def on_load?(line, :historical), do: eligible?(line)
  def on_load?(_line, _mode), do: false

  @doc """
  Marks a historical plot with band-capable lines for the chart hook:
  `_envelope` (the indexes of those series; the first load was read as an
  envelope) and `_envelopes` (the first load's band payloads, from
  `envelopes`, a list of `{series name, envelope}`). Other plots are
  returned as they are.
  """
  def put(%{option: option} = plot, lines, :historical, envelopes) do
    indexes =
      for line <- lines,
          eligible?(line),
          index = series_index(option, line.series),
          index != nil,
          do: index

    case indexes do
      [] ->
        plot

      indexes ->
        payloads =
          for {series, envelope} <- envelopes,
              payload = payload(option, series, envelope),
              payload != nil,
              do: payload

        option =
          option
          |> Map.put(:_envelope, %{on: true, series: indexes})
          |> Map.put(:_envelopes, payloads)

        %{plot | option: option}
    end
  end

  def put(plot, _lines, _mode, _envelopes), do: plot

  @doc """
  The payload the chart hook draws one band from: the series it belongs to,
  its bucket width, the span it covers and its rows `[t, min, mean, max]`.
  nil without an envelope, or when the plot has no series of that name (no
  band, rather than a band on another line).
  """
  def payload(_option, _series, nil), do: nil

  def payload(option, series, envelope) do
    case series_index(option, series) do
      nil ->
        nil

      index ->
        %{
          seriesIndex: index,
          bucket_ms: envelope.bucket_ms,
          from: envelope.from_ms,
          until: envelope.until_ms,
          rows: envelope.rows
        }
    end
  end

  defp series_index(%{series: series}, name),
    do: Enum.find_index(series, &(Map.get(&1, :name) == name))
end
