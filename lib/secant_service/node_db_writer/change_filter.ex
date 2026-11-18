defmodule SecantService.NodeDBWriter.ChangeFilter do
  @moduledoc """
  Decides which parameter updates are worth storing.

  An update is written when its value differs from the last written value
  (exact term equality, so `1` and `1.0` count as different) or when at least
  `heartbeat_ms` have passed since the last write for that parameter. The
  heartbeat bounds how far back a reader has to look for the current value
  and shows that the parameter was still being observed. It is driven by
  incoming updates only: every stored row is a value the node actually sent.
  """

  @type key :: term()
  @type t :: %{optional(key) => {term(), integer()}}

  @spec new() :: t()
  def new, do: %{}

  @doc """
  Returns `{:write, filter}` or `{:skip, filter}` for `value` arriving at
  `now_ms` (a monotonic millisecond clock).
  """
  @spec check(t(), key, term(), integer(), non_neg_integer()) :: {:write | :skip, t()}
  def check(filter, key, value, now_ms, heartbeat_ms) do
    case Map.get(filter, key) do
      {last_value, written_at} when last_value === value and now_ms - written_at < heartbeat_ms ->
        {:skip, filter}

      _ ->
        {:write, Map.put(filter, key, {value, now_ms})}
    end
  end
end
