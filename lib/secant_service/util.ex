defmodule SecantService.Util do
  @doc """
  Human-readable name from a SECoP identifier: underscores become spaces and
  each word starts upper case. Existing capitals are kept, so `MFC_group_1`
  becomes "MFC Group 1" rather than "Mfc Group 1".
  """
  def display_name(nil), do: ""

  def display_name(name) do
    name
    |> String.split("_", trim: true)
    |> Enum.map(&upcase_first/1)
    |> Enum.join(" ")
  end

  defp upcase_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp upcase_first(word), do: word

  @doc """
  Compact one-line rendering of an arbitrary (JSON-like) value for property
  lists, cut to `max` characters.
  """
  def short_inspect(value, max \\ 140)

  def short_inspect(value, max) when is_binary(value), do: truncate(value, max)

  def short_inspect(value, max) do
    text =
      case Jason.encode(value) do
        {:ok, json} -> json
        {:error, _} -> inspect(value)
      end

    truncate(text, max)
  end

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  def get_highest_if_class(iflist) do
    cond do
      Enum.member?(iflist, "AcquisitionController") -> :acquisition_controller
      Enum.member?(iflist, "AcquisitionChannel") -> :acquisition_channel
      # removed later
      Enum.member?(iflist, "Triggerable") -> :acquisition
      # removed later
      Enum.member?(iflist, "Measurable") -> :acquisition
      Enum.member?(iflist, "Acquisition") -> :acquisition
      # custom calibratable IF class
      Enum.member?(iflist, "_Calibratable") -> :calibratable
      Enum.member?(iflist, "Drivable") -> :drivable
      Enum.member?(iflist, "Readable") -> :readable
      Enum.member?(iflist, "Communicator") -> :communicator
      true -> nil
    end
  end

  @doc """
  Format bytes into human-readable format (B, KB, MB, GB, TB).

  Examples:
      iex> format_bytes(1024)
      "1.0 KB"
      iex> format_bytes(1024 * 1024)
      "1.0 MB"
      iex> format_bytes(512)
      "512 B"
  """
  def format_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes < 1024 ->
        "#{bytes} B"

      bytes < 1024 * 1024 ->
        kb = bytes / 1024
        "#{Float.round(kb, 1)} KB"

      bytes < 1024 * 1024 * 1024 ->
        mb = bytes / (1024 * 1024)
        "#{Float.round(mb, 1)} MB"

      bytes < 1024 * 1024 * 1024 * 1024 ->
        gb = bytes / (1024 * 1024 * 1024)
        "#{Float.round(gb, 1)} GB"

      true ->
        tb = bytes / (1024 * 1024 * 1024 * 1024)
        "#{Float.round(tb, 1)} TB"
    end
  end

  # Handle Decimal values from database aggregates
  def format_bytes(%Decimal{} = bytes) do
    bytes
    |> Decimal.to_integer()
    |> format_bytes()
  end

  # Handle nil
  def format_bytes(nil), do: "0 B"

  # Handle Decimal values from database aggregates

  # Handle nil
end
