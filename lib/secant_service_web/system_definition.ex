defmodule SecantServiceWeb.SystemDefinition do
  @moduledoc """
  A SECoP system schema (RFC-104), defined in code: the system's name, the
  versions this definition handles and, per version, a role module
  (`SecantServiceWeb.SystemRole`) for each role it customises.

  Modules bound to the system in one of those roles (see
  `SecantService.Systems`) can get a custom dashboard card and module plot.
  Roles without a role module, and versions not listed, stay generic.

  Put a system module under `SecantServiceWeb.Systems.` and
  `SecantServiceWeb.Systems` finds it; no registration is needed (see there
  for the settings that list or disable systems explicitly).

      defmodule SecantServiceWeb.Systems.PowerSupply do
        @behaviour SecantServiceWeb.SystemDefinition

        def system, do: "PowerSupply"
        def versions, do: [0]
        def roles(0), do: %{"current" => SecantServiceWeb.Systems.PowerSupply.Current}
      end
  """

  @doc "The system schema's name, as in a node's `systems` entry (`\"PowerSupply\"`)."
  @callback system() :: String.t()

  @doc "The schema versions this definition handles."
  @callback versions() :: [non_neg_integer()]

  @doc "The role modules of `version`, by role name."
  @callback roles(version :: non_neg_integer()) :: %{String.t() => module()}
end
