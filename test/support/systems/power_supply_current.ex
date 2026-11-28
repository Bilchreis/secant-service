defmodule SecantServiceWeb.TestSystems.PowerSupply.Current do
  @moduledoc "Test role: a card showing `control_active`, and a two-axis lines plot."
  @behaviour SecantServiceWeb.SystemRole
  use Phoenix.Component

  import SecantServiceWeb.Systems.Components

  alias SecantService.PlotDB.LinesPlot
  alias SecantService.PlotDB.Trace

  def required_parameters, do: ["control_active"]

  def card, do: %{body: &body/1, shown_parameters: ["value", "control_active"]}

  def plot do
    %LinesPlot{
      traces: [
        %Trace{param: "value"},
        %Trace{param: "target", setpoint?: true},
        %Trace{param: "voltage_limit", axis: 1},
        %Trace{param: "power_limit", hidden?: true}
      ]
    }
  end

  def body(assigns) do
    ~H"""
    <div id={"sys-body-" <> @module.name} class="flex flex-col gap-1.5">
      <.card_param node={@node} module={@module} location={@location} name="value" variant={:hero} />
      <.card_param node={@node} module={@module} location={@location} name="control_active" />
    </div>
    """
  end
end
