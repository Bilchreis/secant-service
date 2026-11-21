defmodule SecantServiceWeb.CommandDisplayTest do
  use ExUnit.Case, async: true

  alias SecantServiceWeb.Components.CommandDisplay

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        id_str: "cmd",
        module_name: "mod",
        command: %{name: "go"}
      }
    }
  end

  # secant_client answers {:error, :not_connected} at once when the TCP link
  # is down, instead of waiting for the request to time out.
  test "a command the node could not be sent reports the node as not connected" do
    assert {:ok, socket} =
             CommandDisplay.update(%{return_value: {:error, :not_connected}}, socket())

    assert socket.assigns.last_result == {:error, "Not sent: node not connected"}
  end
end
