defmodule SecantService.Util do
  def display_name(name) do
    name
    |> String.split("_")
    |> Enum.map(fn x -> String.capitalize(x) end)
    |> Enum.join(" ")
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

  @doc """
  Calculate log-scaled opacity value (0-100) for a given byte size.

  Uses logarithmic scale to map byte sizes to a 0-100 range.
  Assumes typical range: 1 KB to 100 GB.

  Returns an integer from 0-100 representing the opacity percentage.
  """
  def calculate_log_gradient(bytes) when is_integer(bytes) and bytes >= 0 do
    # Define min and max thresholds in bytes
    # 1 KB
    min_bytes = 1024
    # 100 GB
    max_bytes = 100 * 1024 * 1024 * 1024

    clamped = min(max(bytes, min_bytes), max_bytes)

    # Calculate log scale (base 10)
    log_min = :math.log10(min_bytes)
    log_max = :math.log10(max_bytes)
    log_value = :math.log10(clamped)

    # Map to 0-100 range
    normalized = (log_value - log_min) / (log_max - log_min)
    opacity = round(normalized * 100)

    max(0, min(100, opacity))
  end

  @doc """
  Generate Tailwind gradient classes for disk size visualization.

  Returns string with daisyUI color gradient classes based on log-scaled opacity.
  """
  def disk_size_gradient_classes(bytes) when is_integer(bytes) and bytes >= 0 do
    opacity = calculate_log_gradient(bytes)

    # Map opacity (0-100) to daisyUI neutral->primary gradient
    # Using opacity/10 to get daisyUI opacity scale (0, 5, 10, ..., 100)
    opacity_class = opacity_to_class(opacity)

    "bg-gradient-to-r from-neutral to-primary #{opacity_class}"
  end

  @doc """
  Format a number in scientific notation with E notation.

  Examples:
      iex> format_scientific(2850)
      "2.85E3"
      iex> format_scientific(25617)
      "2.56E4"
      iex> format_scientific(100)
      "1.00E2"
  """
  def format_scientific(num) when is_integer(num) and num > 0 do
    # Calculate exponent
    exponent = :math.log10(num) |> floor()

    # Calculate mantissa (coefficient)
    mantissa = num / :math.pow(10, exponent)

    # Format mantissa to 2 decimal places
    mantissa_str = :erlang.float_to_binary(mantissa, decimals: 2)

    "#{mantissa_str}E#{exponent}"
  end

  def format_scientific(0), do: "0"
  def format_scientific(num) when is_integer(num) and num < 0, do: "-#{format_scientific(-num)}"

  # Handle Decimal values from database aggregates
  def format_scientific(%Decimal{} = num) do
    num
    |> Decimal.to_integer()
    |> format_scientific()
  end

  # Handle nil
  def format_scientific(nil), do: "0"

  defp opacity_to_class(opacity) when opacity <= 10, do: "opacity-10"
  defp opacity_to_class(opacity) when opacity <= 20, do: "opacity-20"
  defp opacity_to_class(opacity) when opacity <= 30, do: "opacity-30"
  defp opacity_to_class(opacity) when opacity <= 40, do: "opacity-40"
  defp opacity_to_class(opacity) when opacity <= 50, do: "opacity-50"
  defp opacity_to_class(opacity) when opacity <= 60, do: "opacity-60"
  defp opacity_to_class(opacity) when opacity <= 70, do: "opacity-70"
  defp opacity_to_class(opacity) when opacity <= 80, do: "opacity-80"
  defp opacity_to_class(opacity) when opacity <= 90, do: "opacity-90"
  defp opacity_to_class(_opacity), do: "opacity-100"
end
