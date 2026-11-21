defmodule SecantServiceWeb.TelemetryTest do
  use ExUnit.Case, async: true

  test "the number of recording nodes is measured" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:secant_service, :nodes, :recording]])
    SecantServiceWeb.Telemetry.measure_recording()

    assert_receive {[:secant_service, :nodes, :recording], ^ref, %{count: n}, _}
                   when is_integer(n)
  end
end
