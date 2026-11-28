defmodule SecantService.PlotDB.Gaps do
  @moduledoc """
  Gaps of a session: time in which it was not recorded, from its recording
  spans (`SecantService.SecNodes.RecordingSpan`). Number-line plots and
  numeric array plots (not setpoints) get them as intervals `[g0, g1]` or
  `[g0, g1, reason]` (Unix milliseconds; `g1` nil when no span follows), and
  the chart hook breaks the lines and ends the heatmap rows there, and marks
  them with a region that names the reason (`assets/js/charts/gaps.mjs`).

    * A gap is time after the session's first span that no span covers,
      including the time after its last span. Time before the first span is
      no gap.
    * An open span whose `alive_until` is more than #{div(45_000, 1000)} s old
      ends there: its tracker is gone (a server kill, a power loss). An open
      span alive more recently ends now.
    * A gap's reason is the `end_reason` of the span whose end starts it, as
      a string: why recording stopped. A stale open span gives
      `"interrupted"`, as the tracker closes such a span once it finds it.
      Without a reason the gap has two elements.
    * Sessions without any span (recorded before spans existed) get
      `:no_spans`; their number plots break `value` lines by the spacing of
      the readings instead, using the module's poll interval
      (`pollinterval_ms/1`). Array plots get no such fallback.

  The plots send gaps with every load (`put/3`, `reply/4`), all of them:
  the hook decides which it can draw at the current zoom, and a short gap
  that closes an open one it knew must reach it.
  """

  import Ecto.Query

  alias SecantService.PlotDB.DTypes.Scalar
  alias SecantService.Repo

  @stale_ms 45_000

  @type gap :: [integer | nil | String.t()]

  @doc """
  The gaps of the session of parameter `param_id` that overlap
  `from_ms..to_ms` (nil: unbounded), as `{:spans, [[g0, g1]]}`, or
  `:no_spans`. One query, over the session's spans.
  """
  @spec for_param(integer, integer | nil, integer | nil) :: {:spans, [gap]} | :no_spans
  def for_param(param_id, from_ms, to_ms) do
    from(s in "recording_spans",
      join: m in "modules",
      on: m.sec_node_id == s.sec_node_id,
      join: p in "parameters",
      on: p.module_id == m.id,
      where: p.id == ^param_id,
      order_by: s.started_at,
      select: {s.started_at, s.alive_until, s.ended_at, s.end_reason}
    )
    |> Repo.all()
    |> gaps(now_ms(), from_ms, to_ms)
  end

  @doc false
  # The gaps between `spans` (`{started_at, alive_until, ended_at,
  # end_reason}`, oldest first) that overlap the window.
  def gaps([], _now, _from, _to), do: :no_spans

  def gaps(spans, now, from_ms, to_ms) do
    intervals =
      Enum.map(spans, fn {started, alive, ended, reason} ->
        {stop, reason} = span_end(ms(alive), ms(ended), now, reason)
        {ms(started), stop, reason}
      end)

    # the reason travels with the span that ends the covered time so far
    {gaps, last_end, last_reason} =
      Enum.reduce(intervals, {[], nil, nil}, fn {start, stop, reason},
                                                {gaps, prev_end, prev_reason} ->
        gaps =
          if prev_end && start > prev_end,
            do: [gap(prev_end, start, prev_reason) | gaps],
            else: gaps

        if is_nil(prev_end) or stop > prev_end,
          do: {gaps, stop, reason},
          else: {gaps, prev_end, prev_reason}
      end)

    # after the last span, unless it is still open and alive
    gaps = if last_end < now, do: [gap(last_end, nil, last_reason) | gaps], else: gaps

    {:spans, gaps |> Enum.reverse() |> Enum.filter(&overlaps?(&1, from_ms, to_ms))}
  end

  defp span_end(_alive, ended, _now, reason) when is_integer(ended),
    do: {ended, reason_text(reason)}

  defp span_end(alive, nil, now, _reason) when now - alive > @stale_ms, do: {alive, "interrupted"}
  defp span_end(_alive, nil, now, _reason), do: {now, nil}

  defp reason_text(nil), do: nil
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason) when is_binary(reason), do: reason

  defp gap(g0, g1, nil), do: [g0, g1]
  defp gap(g0, g1, reason), do: [g0, g1, reason]

  defp overlaps?([g0, g1 | _], from_ms, to_ms),
    do: (is_nil(to_ms) or g0 <= to_ms) and (is_nil(from_ms) or is_nil(g1) or g1 >= from_ms)

  @doc """
  The poll interval (ms) of the module of parameter `param_id`: the last
  reading of the session of its parameter named `pollinterval`, which SECoP
  gives in seconds. nil without one.
  """
  def pollinterval_ms(param_id) do
    from(r in "readings",
      join: poll in "parameters",
      on: poll.id == r.parameter_id,
      join: p in "parameters",
      on: p.module_id == poll.module_id,
      where: p.id == ^param_id and poll.name == "pollinterval",
      order_by: [desc: r.timestamp],
      limit: 1,
      select: fragment("coalesce(?, ?::float8)", r.value_float, r.value_int)
    )
    |> Repo.one()
    |> case do
      seconds when is_number(seconds) and seconds > 0 -> round(seconds * 1000)
      _ -> nil
    end
  end

  # -- what the plots are sent ---------------------------------------------------

  @doc """
  Puts the gaps of a number-line plot's first load on its option, as
  `_gaps: %{gaps: [[g0, g1]], fallback: %{series index => pollinterval_ms}}`.
  `fallback` lists the `value` lines of a historical plot of a session
  without spans. `window` is `{mode, from_ms, to_ms}` of the load.
  """
  def put(%{option: option, lines: _} = plot, plot_lines, {mode, from_ms, to_ms}) do
    [%{param: first} | _] = plot_lines

    payload =
      case for_param(first.id, from_ms, to_ms) do
        {:spans, gaps} ->
          %{gaps: gaps, fallback: %{}}

        :no_spans ->
          %{
            gaps: [],
            fallback: if(mode == :historical, do: fallback(option, plot_lines), else: %{})
          }
      end

    %{plot | option: Map.put(option, :_gaps, payload)}
  end

  def put(plot, _plot_lines, _window), do: plot

  @doc """
  The gaps for a reply of a plot that has them (a zoomed window, a reloaded
  overview, a widened live range): `%{gaps: [[g0, g1]]}`, with `fallback`
  too when asked (`fallback?: true`, the overview). Empty for other plots.
  """
  def reply(plot, plot_lines, window, opts \\ [])

  def reply(%{option: %{_gaps: _} = option}, plot_lines, {from_ms, to_ms}, opts) do
    [%{param: first} | _] = plot_lines

    case for_param(first.id, from_ms, to_ms) do
      {:spans, gaps} ->
        %{gaps: gaps}

      :no_spans ->
        if Keyword.get(opts, :fallback?, false),
          do: %{gaps: [], fallback: fallback(option, plot_lines)},
          else: %{gaps: []}
    end
  end

  def reply(_plot, _plot_lines, _window, _opts), do: %{}

  # series index => poll interval of the `value` number lines (by parameter
  # name: a parameter plotted on its own is always series "value"); arrays
  # get none
  defp fallback(option, plot_lines) do
    for %{param: %{name: "value"} = param, series: series} <- plot_lines,
        Scalar.supported_type?(param.datainfo),
        index = Enum.find_index(option.series, &(Map.get(&1, :name) == series)),
        index != nil,
        poll = pollinterval_ms(param.id),
        poll != nil,
        into: %{},
        do: {index, poll}
  end

  defp ms(nil), do: nil
  defp ms(%NaiveDateTime{} = ts), do: ts |> DateTime.from_naive!("Etc/UTC") |> ms()
  defp ms(%DateTime{} = ts), do: DateTime.to_unix(ts, :millisecond)

  defp now_ms, do: System.os_time(:millisecond)
end
