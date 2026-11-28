defmodule SecantServiceWeb.SystemsTest do
  @moduledoc """
  Matching a node's modules to the configured system definitions: system
  name, version, role and required parameters, and the order rules.
  """
  use ExUnit.Case, async: false

  alias SecantServiceWeb.Systems
  alias SecantServiceWeb.TestSystems.MfcGroup
  alias SecantServiceWeb.TestSystems.PlotOnly
  alias SecantServiceWeb.TestSystems.PowerSupply
  alias SecantServiceWeb.TestSystems.PowerSupplyAlt

  setup do
    previous = Application.get_env(:secant_service, :systems)
    on_exit(fn -> Application.put_env(:secant_service, :systems, previous) end)
    :ok
  end

  defp configure(systems), do: Application.put_env(:secant_service, :systems, systems)

  defp mod(name, params), do: %{name: name, parameters: Enum.map(params, &%{name: &1})}

  defp sys_node(systems, modules) do
    %{custom_properties: %{"systems" => systems}, modules: modules}
  end

  defp ps(ref \\ "PowerSupply:0", modules \\ %{"current" => "cur", "voltage" => "volt"}),
    do: %{"ps" => %{"system" => ref, "modules" => modules}}

  @modules [
    %{name: "cur", parameters: [%{name: "value"}, %{name: "target"}, %{name: "control_active"}]},
    %{name: "volt", parameters: [%{name: "value"}]}
  ]

  test "no systems configured gives no matches" do
    configure([])
    assert Systems.matches(sys_node(ps(), @modules)) == %{}
  end

  test "a matching version and role match the role module" do
    configure([PowerSupply])
    matches = Systems.matches(sys_node(ps(), @modules))

    assert %{role: PowerSupply.Current, system: PowerSupply, binding: %{role: "current"}} =
             matches["cur"]

    assert %{role: PowerSupply.Voltage} = matches["volt"]
  end

  test "an unhandled version, a role without a module and a missing parameter fall back" do
    configure([PowerSupply])

    assert Systems.matches(sys_node(ps("PowerSupply:1"), @modules)) == %{}

    assert Systems.matches(sys_node(ps("PowerSupply:0", %{"resistance" => "cur"}), @modules)) ==
             %{}

    no_control = [mod("cur", ~w(value)), mod("volt", ~w(value))]
    matches = Systems.matches(sys_node(ps(), no_control))
    refute Map.has_key?(matches, "cur")
    assert %{role: PowerSupply.Voltage} = matches["volt"]
  end

  test "a module bound twice uses its first binding by local name" do
    configure([PowerSupply, MfcGroup])

    systems = %{
      "b_ps" => %{"system" => "PowerSupply:0", "modules" => %{"current" => "cur"}},
      "a_mfc" => %{"system" => "MfcGroup:0", "modules" => %{"group" => "cur"}}
    }

    assert %{system: MfcGroup, binding: %{local_name: "a_mfc"}} =
             Systems.matches(sys_node(systems, @modules))["cur"]
  end

  test "two system modules for one name match in configuration order" do
    configure([PowerSupplyAlt, PowerSupply])
    assert %{role: PlotOnly} = Systems.matches(sys_node(ps(), @modules))["cur"]

    configure([PowerSupply, PowerSupplyAlt])
    assert %{role: PowerSupply.Current} = Systems.matches(sys_node(ps(), @modules))["cur"]

    # the first definition doesn't handle version 1; the next one does
    assert %{role: PlotOnly} = Systems.matches(sys_node(ps("PowerSupply:1"), @modules))["cur"]
  end

  test "a module inside a subsystem matches its inner system" do
    configure([PowerSupply])

    systems =
      Map.put(ps(), "magnet", %{"system" => "VectorMagnet:0", "modules" => %{"X" => "ps"}})

    assert %{role: PowerSupply.Current, binding: %{parents: [%{local_name: "magnet"}]}} =
             Systems.matches(sys_node(systems, @modules))["cur"]
  end

  test "shown_parameters lists the declared pairs of matched roles with a card" do
    configure([PowerSupply, MfcGroup])

    systems =
      Map.put(ps(), "mfc", %{"system" => "MfcGroup:0", "modules" => %{"group" => "group"}})

    modules = @modules ++ [mod("group", ~w(value))]
    shown = Systems.shown_parameters(Systems.matches(sys_node(systems, modules)))

    assert shown ==
             MapSet.new([{"cur", "value"}, {"cur", "control_active"}, {"volt", "value"}])
  end
end
