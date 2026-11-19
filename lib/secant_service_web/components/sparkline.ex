defmodule SecantServiceWeb.Components.Sparkline do
  @moduledoc """
  Trend of a module's `value` (and `target`, when the module has a numeric
  one) over the last 10 minutes, shown on the dashboard cards.

  The browser draws the lines (the `Sparkline` JS hook). The server only
  sends the history once, thinned out, and afterwards the few new readings
  of each 3 s plot-data batch, so it keeps no per-card buffer and re-sends
  no SVG.
  """
  use Phoenix.LiveComponent

  require Logger

  alias SecantService.PlotDB.Builders
  alias SecantServiceWeb.ValueFormat

  @window_ms 10 * 60 * 1000
  # history is reduced to the min and max of this many time buckets
  @buckets 120

  @impl true
  def update(%{append: reports, series: series}, socket) do
    points = to_points(reports)

    socket =
      if points == [] or series not in socket.assigns.series do
        socket
      else
        push_event(socket, "spark-add-#{socket.assigns.id}", %{s: series, p: points})
      end

    {:ok, socket}
  end

  def update(%{value_param: value_param} = assigns, socket) do
    target_param =
      case assigns[:target_param] do
        %{datainfo: datainfo} = param -> if ValueFormat.numeric?(datainfo), do: param
        _ -> nil
      end

    params =
      Enum.reject([{"value", value_param}, {"target", target_param}], &(elem(&1, 1) == nil))

    ids = Enum.map(params, fn {_, p} -> p.id end)

    if socket.assigns[:param_ids] == ids do
      {:ok, socket}
    else
      socket =
        socket
        |> assign(:id, assigns.id)
        |> assign(:param_ids, ids)
        |> assign(:series, Enum.map(params, &elem(&1, 0)))
        |> assign(:unit, ValueFormat.unit(value_param.datainfo))
        |> assign(:history, nil)
        |> assign(:client_ready, false)
        |> start_async(:history, fn -> load_history(params) end)

      {:ok, socket}
    end
  end

  # [[value, %{t: seconds}], ...] -> [[ms, value], ...]
  defp to_points(reports) do
    Enum.flat_map(reports, fn
      [value, %{t: t}] when is_number(t) ->
        case number(value) do
          nil -> []
          v -> [[trunc(t * 1000), v]]
        end

      _ ->
        []
    end)
  end

  defp number(%Decimal{} = v), do: Decimal.to_float(v)
  defp number(v) when is_number(v), do: v
  defp number(_), do: nil

  defp load_history(params) do
    now = System.os_time(:millisecond)

    Map.new(params, fn {series, param} ->
      {values, timestamps} = Builders.fetch_param_data_in_range(param, now - @window_ms, now)

      points =
        timestamps
        |> Enum.zip(values)
        |> Enum.flat_map(fn {t, v} ->
          case number(v) do
            nil -> []
            n -> [{t, n}]
          end
        end)
        |> Enum.sort_by(&elem(&1, 0))
        |> thin(@buckets)
        |> Enum.map(fn {t, v} -> [t, v] end)

      {series, points}
    end)
  end

  @doc """
  Reduces readings to the min and max of `buckets` equal-count chunks, in time
  order, so a short spike survives. Fewer readings pass through unchanged.
  """
  def thin(points, buckets) when length(points) <= 2 * buckets, do: points

  def thin(points, buckets) do
    points
    |> Enum.chunk_every(ceil(length(points) / buckets))
    |> Enum.flat_map(fn chunk ->
      lo = Enum.min_by(chunk, &elem(&1, 1))
      hi = Enum.max_by(chunk, &elem(&1, 1))
      [lo, hi] |> Enum.uniq() |> Enum.sort_by(&elem(&1, 0))
    end)
  end

  @impl true
  def handle_async(:history, {:ok, history}, socket) do
    socket = assign(socket, :history, history)
    {:noreply, maybe_push_history(socket)}
  end

  def handle_async(:history, {:exit, reason}, socket) do
    Logger.warning("Sparkline history failed: #{inspect(reason)}")
    socket = assign(socket, :history, %{})
    {:noreply, maybe_push_history(socket)}
  end

  # the hook announces itself; history goes out once both sides are ready
  @impl true
  def handle_event("spark-ready", _params, socket) do
    {:noreply, socket |> assign(:client_ready, true) |> maybe_push_history()}
  end

  defp maybe_push_history(%{assigns: %{client_ready: true, history: history}} = socket)
       when is_map(history) do
    push_event(socket, "spark-init-#{socket.assigns.id}", history)
  end

  defp maybe_push_history(socket), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="Sparkline"
      phx-update="ignore"
      data-unit={@unit}
      class="relative h-8"
      role="img"
      aria-label={
        if "target" in @series,
          do: "trend of value and target over the last 10 minutes",
          else: "trend over the last 10 minutes"
      }
    >
      <div
        data-role="empty"
        class="absolute inset-x-0 top-1/2 border-t border-dashed border-line"
      >
      </div>
      <div data-role="chart" class="absolute inset-0"></div>
    </div>
    """
  end
end
