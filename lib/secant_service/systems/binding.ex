defmodule SecantService.Systems.Binding do
  @moduledoc """
  A module's place in one SECoP system of its node (see `SecantService.Systems`):
  the role `role` of the system entry `local_name`, which implements the
  schema `system` in version `version`.

  `parents` lists the systems that contain this one as a subsystem, innermost
  first, as `%{local_name:, system:, version:, role:}`, where `role` is the
  role that names the inner system.
  """

  @enforce_keys [:local_name, :system, :version, :role, :module]
  defstruct [:local_name, :system, :version, :role, :module, description: nil, parents: []]

  @type parent :: %{
          local_name: String.t(),
          system: String.t(),
          version: non_neg_integer(),
          role: String.t()
        }

  @type t :: %__MODULE__{
          local_name: String.t(),
          system: String.t(),
          version: non_neg_integer(),
          role: String.t(),
          module: String.t(),
          description: String.t() | nil,
          parents: [parent()]
        }

  @doc "The binding's system reference, e.g. `PowerSupply:0`."
  def reference(%{system: system, version: version}), do: "#{system}:#{version}"
end
