defmodule SecantService.DBErrors do
  @moduledoc """
  Telling a database failure that may pass from one that won't, for the
  processes that keep writing through outages (`SecantService.NodeDBWriter`,
  `SecantService.RecordingTracker`).
  """

  @doc """
  Positive evidence that the failure may pass: no connection, or Postgres
  saying so (SQLSTATE 08 connection, 40 rollback, 53 resources, 57 operator
  intervention, 55P03 lock not available). Looks into Ash errors, lists and
  maps of them.
  """
  def transient?(%DBConnection.ConnectionError{}), do: true
  def transient?(%Ash.Error.Invalid.Unavailable{}), do: true

  def transient?(%Postgrex.Error{
        postgres: %{pg_code: <<class::binary-size(2), _::binary>> = code}
      }),
      do: class in ["08", "40", "53", "57"] or code == "55P03"

  def transient?(list) when is_list(list), do: Enum.any?(list, &transient?/1)
  def transient?(%{} = map), do: map |> Map.delete(:__struct__) |> Map.values() |> transient?()
  # AshPostgres keeps some errors only as their formatted text
  def transient?(text) when is_binary(text),
    do: String.contains?(text, "DBConnection.ConnectionError")

  def transient?(_other), do: false
end
