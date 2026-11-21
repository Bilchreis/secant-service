defmodule SecantServiceWeb.ParameterValueDisplayTest do
  use ExUnit.Case, async: true

  alias SecantServiceWeb.Components.ParameterValueDisplay

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}, set_pending: false}, assigns)}
  end

  test "a Set on a read-only parameter is rejected on the server" do
    socket = socket(%{parameter: %{readonly: true, name: "value"}, set_feedback: nil})

    params = %{"form_type" => "simple", "value" => "1.0", "parameter" => "target"}

    assert {:ok, socket} =
             ParameterValueDisplay.update(
               %{control: :set_parameter, unsigned_params: params},
               socket
             )

    assert socket.assigns.set_feedback == {:error, "This parameter is read-only"}
  end
end
