defmodule SecantServiceWeb.TestSystems.PowerSupply.Voltage do
  @moduledoc "Test role: a card and no plot."
  @behaviour SecantServiceWeb.SystemRole
  use Phoenix.Component

  import SecantServiceWeb.Systems.Components

  def required_parameters, do: []
  def card, do: %{body: &body/1, shown_parameters: ["value"]}
  def plot, do: nil

  def body(assigns) do
    ~H"""
    <div id={"sys-body-" <> @module.name}>
      <.card_param node={@node} module={@module} location={@location} name="value" variant={:hero} />
    </div>
    """
  end
end
