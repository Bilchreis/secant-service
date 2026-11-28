defmodule SecantService.SystemsTest do
  @moduledoc """
  Bindings from the `systems` node property (SECoP RFC-104): which modules
  play which role in which versioned system, and which systems contain those
  as subsystems.
  """
  use SecantService.DataCase, async: true

  alias SecantService.DescribeMessageTransformer
  alias SecantService.NodeFixtures
  alias SecantService.SecNodes
  alias SecantService.Systems
  alias SecantService.Systems.Binding

  defp sys_node(systems, modules \\ ~w(magcur_x magvolt_x magtemp other)) do
    %{custom_properties: %{"systems" => systems}, modules: Enum.map(modules, &%{name: &1})}
  end

  @power_supply %{
    "mag5t_x" => %{
      "system" => "PowerSupply:0",
      "description" => "X axis",
      "modules" => %{"current" => "magcur_x", "voltage" => "magvolt_x"}
    }
  }

  describe "bindings from the systems property" do
    test "binds each named module with its role" do
      bindings = Systems.bindings(sys_node(@power_supply))

      assert [
               %Binding{
                 local_name: "mag5t_x",
                 system: "PowerSupply",
                 version: 0,
                 role: "current",
                 module: "magcur_x",
                 description: "X axis",
                 parents: []
               }
             ] = bindings["magcur_x"]

      assert [%Binding{role: "voltage", system: "PowerSupply"}] = bindings["magvolt_x"]
      assert Systems.bindings_for(sys_node(@power_supply), "other") == []
    end

    test "a node without systems has no bindings" do
      assert Systems.bindings(%{custom_properties: %{}, modules: [%{name: "a"}]}) == %{}
      assert Systems.bindings(%{custom_properties: nil, modules: []}) == %{}
    end

    test "reads atom keys, as a description has them before it is stored" do
      node = %{
        custom_properties: %{
          systems: %{mag5t_x: %{system: "PowerSupply:0", modules: %{current: "magcur_x"}}}
        },
        modules: [%{name: "magcur_x"}]
      }

      assert [%Binding{local_name: "mag5t_x", role: "current"}] =
               Systems.bindings_for(node, "magcur_x")
    end
  end

  describe "system reference and version" do
    test "no version means version 0, and a version is read" do
      assert {:ok, "PowerSupply", 0} = Systems.parse_reference("PowerSupply")
      assert {:ok, "PowerSupply", 2} = Systems.parse_reference("PowerSupply:2")
      assert {:ok, "PowerSupply", 0} = Systems.parse_reference("PowerSupply:0")
    end

    test "malformed versions drop the entry" do
      for ref <-
            ["PowerSupply:beta", "PowerSupply:", "PowerSupply:1.0", "PowerSupply:-1"] ++
              ["PowerSupply:1\n", ":1", "", 5, nil] do
        assert Systems.parse_reference(ref) == :error, inspect(ref)
      end

      systems =
        Map.put(@power_supply, "bad", %{
          "system" => "PowerSupply:beta",
          "modules" => %{"T" => "magtemp"}
        })

      bindings = Systems.bindings(sys_node(systems))
      assert bindings["magtemp"] == nil
      assert [_] = bindings["magcur_x"]
    end
  end

  describe "subsystems" do
    @magnet Map.put(@power_supply, "mag5t", %{
              "system" => "VectorMagnet:0",
              "modules" => %{"T" => "magtemp", "X" => "mag5t_x"}
            })

    test "a subsystem's modules keep their binding and record the parent" do
      assert [
               %Binding{
                 local_name: "mag5t_x",
                 system: "PowerSupply",
                 role: "current",
                 parents: [%{local_name: "mag5t", system: "VectorMagnet", version: 0, role: "X"}]
               }
             ] = Systems.bindings_for(sys_node(@magnet), "magcur_x")

      # the vector magnet binds only its own module, not the subsystem's again
      assert [%Binding{local_name: "mag5t", role: "T"}] =
               Systems.bindings_for(sys_node(@magnet), "magtemp")
    end

    test "two levels of nesting give the parents innermost first" do
      systems =
        Map.put(@magnet, "lab", %{"system" => "Lab:0", "modules" => %{"magnet" => "mag5t"}})

      assert [
               %{
                 parents: [
                   %{local_name: "mag5t", role: "X"},
                   %{local_name: "lab", role: "magnet"}
                 ]
               }
             ] =
               Systems.bindings_for(sys_node(systems), "magcur_x")
    end

    test "a subsystem contained twice follows the first container by local name" do
      systems = Map.put(@magnet, "rig", %{"system" => "Rig:0", "modules" => %{"x" => "mag5t_x"}})

      assert [%{parents: [%{local_name: "mag5t"}]}] =
               Systems.bindings_for(sys_node(systems), "magcur_x")
    end

    test "a cycle ends" do
      systems = %{
        "a" => %{"system" => "A:0", "modules" => %{"inner" => "b", "m" => "magcur_x"}},
        "b" => %{"system" => "B:0", "modules" => %{"outer" => "a", "m" => "magvolt_x"}}
      }

      assert [%{local_name: "a", parents: [%{local_name: "b"}]}] =
               Systems.bindings_for(sys_node(systems), "magcur_x")

      assert [%{local_name: "b", parents: [%{local_name: "a"}]}] =
               Systems.bindings_for(sys_node(systems), "magvolt_x")
    end
  end

  describe "entries that bind nothing" do
    test "a role naming neither a module nor an entry is skipped" do
      systems = put_in(@power_supply, ["mag5t_x", "modules", "power"], "magpow_x")
      bindings = Systems.bindings(sys_node(systems))

      assert Map.keys(bindings) |> Enum.sort() == ["magcur_x", "magvolt_x"]
    end

    test "an entry without a modules mapping gives nothing" do
      assert Systems.bindings(sys_node(%{"x" => %{"system" => "PowerSupply:0"}})) == %{}
    end

    test "a value naming both a module and a local system is read as the module" do
      systems =
        Map.merge(@power_supply, %{
          "magtemp" => %{"system" => "Thermo:0", "modules" => %{"t" => "other"}},
          "outer" => %{"system" => "Outer:0", "modules" => %{"thing" => "magtemp"}}
        })

      assert [%{local_name: "outer", role: "thing"}] =
               Systems.bindings_for(sys_node(systems), "magtemp")

      assert [%{local_name: "magtemp", parents: []}] =
               Systems.bindings_for(sys_node(systems), "other")
    end
  end

  describe "reading never fails" do
    test "systems that is not an object gives nothing" do
      assert Systems.bindings(sys_node(["PowerSupply"])) == %{}
      assert Systems.bindings(sys_node("PowerSupply")) == %{}
    end

    test "entries and role values of the wrong type are skipped" do
      systems = %{
        "five" => 5,
        "ps" => %{
          "system" => "PowerSupply:0",
          "modules" => %{"current" => %{"name" => "magcur_x"}, "voltage" => "magvolt_x", "x" => 3}
        },
        "list" => %{"system" => "PowerSupply:0", "modules" => ["magtemp"]},
        "nosys" => %{"system" => %{"name" => "PowerSupply"}, "modules" => %{"t" => "magtemp"}}
      }

      bindings = Systems.bindings(sys_node(systems))
      assert Map.keys(bindings) == ["magvolt_x"]
      assert [%{role: "voltage"}] = bindings["magvolt_x"]
    end
  end

  test "a module in several systems has one binding each, ordered by local name" do
    systems = %{
      "mag5t" => %{"system" => "VectorMagnet:0", "modules" => %{"T" => "magtemp"}},
      "cryo1" => %{"system" => "OrangeCryostat:0", "modules" => %{"T" => "magtemp"}}
    }

    assert [%{local_name: "cryo1"}, %{local_name: "mag5t"}] =
             Systems.bindings_for(sys_node(systems), "magtemp")
  end

  test "the stored node gives the same bindings as the description" do
    systems = %{
      mag5t_x: %{
        system: "PowerSupply:0",
        description: "X axis",
        modules: %{current: "magcur_x", voltage: "magvolt_x"}
      },
      mag5t: %{system: "VectorMagnet:0", modules: %{X: "mag5t_x"}}
    }

    raw =
      "eq-systems"
      |> NodeFixtures.raw_description(%{"magcur_x" => ["value"], "magvolt_x" => ["value"]})
      |> NodeFixtures.put_systems(systems)

    state = NodeFixtures.node_state({~c"127.0.0.1", 1}, raw)
    transformed = DescribeMessageTransformer.transform(state)

    {:ok, record} = SecNodes.upsert_sec_node(transformed)
    stored = SecNodes.get_sec_node!(record.uuid)

    # stored JSON has string keys
    assert %{"systems" => %{"mag5t_x" => _}} = stored.custom_properties

    fresh = %{custom_properties: transformed.custom_properties, modules: transformed.modules}
    assert Systems.bindings(stored) == Systems.bindings(fresh)

    assert [%Binding{role: "current", parents: [%{local_name: "mag5t", role: "X"}]}] =
             Systems.bindings_for(stored, "magcur_x")
  end
end
