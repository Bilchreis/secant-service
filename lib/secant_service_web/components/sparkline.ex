defmodule SecantServiceWeb.Components.Sparkline do
  @moduledoc """
  Small trend line of a numeric parameter over the last 10 minutes, shown on
  the dashboard cards. History comes from the database on mount; live points
  arrive through `send_update(..., append: data_reports)` from the plot-data
  batches the dashboard already receives.

  Rendered as an SVG polyline on the server, so it needs no JS hook.
  """
  use Phoenix.LiveComponent

  require Logger

  alias SecantService.PlotDB.Builders

  @window_ms 10 * 60 * 1000
  @max_points 600
  @width 200
  # above this many readings the line is reduced to min/max per bucket
  @buckets 100
  @height 32

  @impl true
  def mount(socket) do
    {:ok, assign(socket, points: [], loaded: false)}
  end

  @impl true
  def update(%{append: reports}, socket) do
    new_points =
      Enum.flat_map(reports, fn
        [value, %{t: t}] when is_number(value) and is_number(t) -> [{trunc(t * 1000), value}]
        _ -> []
      end)

    {:ok, assign(socket, :points, trim(socket.assigns.points ++ new_points))}
  end

  def update(%{parameter: parameter} = assigns, socket) do
    if socket.assigns[:parameter] && socket.assigns.parameter.id == parameter.id do
      {:ok, socket}
    else
      socket =
        socket
        |> assign(:id, assigns.id)
        |> assign(:parameter, parameter)
        |> assign(:points, [])
        |> assign(:loaded, false)
        |> start_async(:history, fn -> load_history(parameter) end)

      {:ok, socket}
    end
  end

  defp load_history(parameter) do
    now = System.os_time(:millisecond)
    {values, timestamps} = Builders.fetch_param_data_in_range(parameter, now - @window_ms, now)

    # double/scaled values are stored as numeric columns and come back as Decimal
    timestamps
    |> Enum.zip(values)
    |> Enum.flat_map(fn
      {t, %Decimal{} = v} -> [{t, Decimal.to_float(v)}]
      {t, v} when is_number(v) -> [{t, v}]
      _ -> []
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @impl true
  def handle_async(:history, {:ok, history}, socket) do
    # keep live points that arrived while the history query ran
    last = List.last(history)
    last_ts = if last, do: elem(last, 0), else: 0
    live = Enum.filter(socket.assigns.points, fn {t, _} -> t > last_ts end)

    {:noreply, socket |> assign(:points, trim(history ++ live)) |> assign(:loaded, true)}
  end

  def handle_async(:history, {:exit, reason}, socket) do
    Logger.warning("Sparkline history failed: #{inspect(reason)}")
    {:noreply, assign(socket, :loaded, true)}
  end

  defp trim(points) do
    cutoff = System.os_time(:millisecond) - @window_ms

    points
    |> Enum.drop_while(fn {t, _} -> t < cutoff end)
    |> Enum.take(-@max_points)
  end

  @doc false
  # Step line (each reading holds until the next one, which is right for
  # sparse change-only data too). x spans the last 10 minutes, or less when
  # there is less data so a freshly connected node still gets a full line.
  def polyline([], _now), do: nil

  def polyline(points, now) do
    {lo, hi} = points |> Enum.map(&elem(&1, 1)) |> Enum.min_max()
    span = if hi == lo, do: nil, else: hi - lo
    {first_ts, _} = hd(points)
    start = max(now - @window_ms, min(first_ts, now - 60_000))
    window = max(now - start, 1)

    x = fn t -> max(0.0, (t - start) / window * @width) end
    y = fn v -> if span, do: @height - 3 - (v - lo) / span * (@height - 6), else: @height / 2 end

    {_, last_v} = List.last(points)

    coords =
      if length(points) <= @buckets do
        # sparse: hold each reading until the next one
        {coords, _} =
          Enum.reduce(points, {[], nil}, fn {t, v}, {acc, prev} ->
            acc = if prev == nil, do: acc, else: [{x.(t), y.(prev)} | acc]
            {[{x.(t), y.(v)} | acc], v}
          end)

        Enum.reverse(coords)
      else
        # dense: min and max of each bucket, in time order, so peaks survive
        points
        |> Enum.chunk_every(ceil(length(points) / @buckets))
        |> Enum.flat_map(fn chunk ->
          lo_pt = Enum.min_by(chunk, &elem(&1, 1))
          hi_pt = Enum.max_by(chunk, &elem(&1, 1))
          Enum.uniq(Enum.sort_by([lo_pt, hi_pt], &elem(&1, 0)))
        end)
        |> Enum.map(fn {t, v} -> {x.(t), y.(v)} end)
      end

    (coords ++ [{x.(now), y.(last_v)}])
    |> Enum.map_join(" ", fn {cx, cy} ->
      "#{Float.round(cx * 1.0, 1)},#{Float.round(cy * 1.0, 1)}"
    end)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :line, polyline(assigns.points, System.os_time(:millisecond)))

    ~H"""
    <div id={@id} class="relative" title="last 10 minutes">
      <svg
        viewBox={"0 0 #{width()} #{height()}"}
        preserveAspectRatio="none"
        class="block h-8 w-full"
        role="img"
        aria-label={"#{@parameter.name}, last 10 minutes"}
      >
        <line
          :if={@line == nil}
          x1="0"
          x2={width()}
          y1={height() / 2}
          y2={height() / 2}
          stroke="currentColor"
          class="text-line"
          stroke-dasharray="3 3"
          vector-effect="non-scaling-stroke"
        />
        <polyline
          :if={@line}
          points={@line}
          fill="none"
          stroke="currentColor"
          class="text-primary"
          stroke-width="1.5"
          stroke-linejoin="round"
          vector-effect="non-scaling-stroke"
        />
      </svg>
      <span
        :if={@loaded and @line == nil}
        class="absolute inset-0 flex items-center justify-center text-[10.5px] text-muted"
      >
        <span class="bg-base-100 px-1">no data in the last 10 min</span>
      </span>
    </div>
    """
  end

  defp width, do: @width
  defp height, do: @height
end
