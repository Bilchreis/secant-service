defmodule SecantServiceWeb.InFlight do
  @moduledoc """
  Remembers which node operations (parameter changes, commands) a dashboard
  is still waiting for, so that the same change cannot be sent twice while
  the first is outstanding, even when it is offered by several widgets (a
  module card and the inspector) or the widget that sent it was re-mounted.

  All components of a LiveView run in the LiveView's process, so the state
  lives in that process and is private to one browser tab. An entry expires
  after `@ttl_ms` in case the answer never arrives (e.g. the sending widget
  was removed before the reply came back).
  """

  @ttl_ms 30_000

  @doc "Marks `key` as in flight. Returns false if it already is."
  def claim(key) do
    now = System.monotonic_time(:millisecond)

    case Process.get({__MODULE__, key}) do
      started when is_integer(started) and now - started < @ttl_ms ->
        false

      _ ->
        Process.put({__MODULE__, key}, now)
        true
    end
  end

  @doc "Marks `key` as finished."
  def release(key) do
    Process.delete({__MODULE__, key})
    :ok
  end
end
