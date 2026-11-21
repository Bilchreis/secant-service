defmodule SecantService.NodeControlTest do
  @moduledoc """
  Validation of values before they are sent to a node. Datainfo comes from the
  database with string keys; values come from what the user typed.
  """
  use ExUnit.Case, async: true

  alias SecantService.NodeControl

  defp form(params \\ %{}), do: Phoenix.Component.to_form(params)

  defp ok?(datainfo, value),
    do: match?({:ok, _}, NodeControl.validate_against_datainfo(datainfo, value))

  describe "validate_against_datainfo/2" do
    test "numbers respect min and max" do
      di = %{"type" => "double", "min" => 0, "max" => 10}
      assert ok?(di, 5.5)
      refute ok?(di, -1)
      refute ok?(di, 11)
      refute ok?(di, "5")

      int = %{"type" => "int", "min" => 1, "max" => 3}
      assert ok?(int, 2)
      refute ok?(int, 2.5)
      refute ok?(int, 4)
    end

    test "enum values must be members" do
      di = %{"type" => "enum", "members" => %{"off" => 0, "on" => 1}}
      assert ok?(di, 1)
      refute ok?(di, 2)
      refute ok?(di, "on")
    end

    test "strings respect length and the ASCII rule" do
      di = %{"type" => "string", "maxchars" => 3}
      assert ok?(di, "abc")
      refute ok?(di, "abcd")
      refute ok?(di, "äb")
      assert ok?(Map.put(di, "isUTF8", true), "äb")
    end

    test "arrays check length and members" do
      di = %{"type" => "array", "minlen" => 1, "maxlen" => 2, "members" => %{"type" => "int"}}
      assert ok?(di, [1, 2])
      refute ok?(di, [])
      refute ok?(di, [1, 2, 3])
      refute ok?(di, [1, 1.5])
    end

    test "tuples check arity and member types" do
      di = %{"type" => "tuple", "members" => [%{"type" => "int"}, %{"type" => "string"}]}
      assert ok?(di, [1, "a"])
      refute ok?(di, [1])
      refute ok?(di, ["a", 1])
    end

    test "struct members listed as optional may be omitted" do
      di = %{
        "type" => "struct",
        "members" => %{"a" => %{"type" => "int"}, "b" => %{"type" => "int"}},
        "optional" => ["b"]
      }

      assert ok?(di, %{"a" => 1})
      assert ok?(di, %{"a" => 1, "b" => 2})
      refute ok?(di, %{"b" => 2})
      assert {:error, "Field 'a'" <> _} = NodeControl.validate_against_datainfo(di, %{"a" => "x"})
    end

    test "matrix values with len and blob validate" do
      di = %{"type" => "matrix", "names" => ["x", "y"], "maxlen" => [4, 4]}
      blob = Base.encode64(<<0::64>>)

      assert ok?(di, %{"len" => [2, 2], "blob" => blob})
      refute ok?(di, %{"len" => [5, 2], "blob" => blob})
      refute ok?(di, %{"len" => [2], "blob" => blob})
      refute ok?(di, %{"len" => [2, 2], "blob" => "not base64!"})
    end
  end

  describe "validate/3" do
    test "accepts plain text for a string parameter" do
      f = NodeControl.validate(%{"value" => "hello"}, %{"type" => "string"}, form())
      assert f.errors == []
      assert f.params["value"] == ~s("hello")
    end

    test "decodes struct values without creating atoms" do
      di = %{"type" => "struct", "members" => %{"a" => %{"type" => "int"}}}
      key = "never_seen_member_#{System.unique_integer([:positive])}"

      f = NodeControl.validate(%{"value" => ~s({"a": 1, "#{key}": 2})}, di, form())
      assert f.errors == []
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end

    test "explains a decimal comma" do
      f = NodeControl.validate(%{"value" => "1,5"}, %{"type" => "double"}, form())
      assert [value: {"Use a decimal point, e.g. 1.5", []}] = f.errors
    end
  end

  describe "validate_modal/3" do
    @struct_di %{
      "type" => "struct",
      "members" => %{
        "speed" => %{"type" => "double", "max" => 10},
        "pos" => %{"type" => "tuple", "members" => [%{"type" => "int"}, %{"type" => "int"}]}
      }
    }

    @current %{"speed" => 1.0, "pos" => [0, 0]}

    defp modal(value), do: form(%{"value" => Jason.encode!(value)})

    test "a valid member edit is merged into the whole value" do
      params = %{
        "_target" => ["value.speed"],
        "value" => Jason.encode!(@current),
        "value.speed" => "2.5"
      }

      f = NodeControl.validate_modal(params, @struct_di, modal(@current))

      assert f.errors == []
      assert Jason.decode!(f.params["value"]) == %{"speed" => 2.5, "pos" => [0, 0]}
    end

    test "a tuple element inside a struct can be edited" do
      params = %{
        "_target" => ["value.pos.f1"],
        "value" => Jason.encode!(@current),
        "value.pos.f1" => "7"
      }

      f = NodeControl.validate_modal(params, @struct_di, modal(@current))
      assert Jason.decode!(f.params["value"])["pos"] == [0, 7]
    end

    test "an invalid member is reported on that member's field" do
      params = %{
        "_target" => ["value.speed"],
        "value" => Jason.encode!(@current),
        "value.speed" => "99"
      }

      f = NodeControl.validate_modal(params, @struct_di, modal(@current))
      assert [{"Value 99 is above maximum 10", []}] = f["value.speed"].errors
      assert Jason.decode!(f.params["value"])["speed"] == 1.0
    end

    test "unknown field names are ignored and create no atoms" do
      name = "value.bogus_#{System.unique_integer([:positive])}"

      params = %{
        "_target" => [name],
        "value" => Jason.encode!(@current),
        name => "1"
      }

      f = NodeControl.validate_modal(params, @struct_di, modal(@current))
      assert f.errors == []
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end
end
