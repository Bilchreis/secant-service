defmodule SecantServiceWeb.Systems do
  @moduledoc """
  Finds the system definitions (`SecantServiceWeb.SystemDefinition`) and
  matches a node's modules to them.

  ## Finding them

  A system definition is found when its module sits under
  `SecantServiceWeb.Systems.` and declares
  `@behaviour SecantServiceWeb.SystemDefinition`; no registration is needed.
  They are tried by module name. Two optional settings override that:

    * `config :secant_service, :systems, [Mod, …]` uses exactly that list,
      in that order (tests register their test systems this way);
    * `config :secant_service, :disabled_systems, [Mod, …]` leaves those out.

  The module list is the application's, read when it is loaded: a running
  dev server finds a newly added system module after a restart (edits to an
  existing one reload as usual).

  ## Matching

  A module matches when one of its bindings (`SecantService.Systems`) has a
  configured system's name and one of its versions, that version has a role
  module (`SecantServiceWeb.SystemRole`) for the binding's role, and the
  module has every parameter the role requires. Bindings are tried in their
  order (by local system name), and system definitions in the order above;
  the first full match wins.

  The settings are read at call time, so tests can change them with
  `Application.put_env/3`.
  """

  alias SecantService.Systems

  @type match :: %{system: module(), role: module(), binding: SecantService.Systems.Binding.t()}

  @namespace "Elixir.SecantServiceWeb.Systems."

  @doc "The system definitions in use: found or listed, without the disabled ones."
  def configured do
    disabled = Application.get_env(:secant_service, :disabled_systems, [])

    systems =
      case Application.get_env(:secant_service, :systems) do
        listed when is_list(listed) -> listed
        _ -> discovered()
      end

    Enum.reject(systems, &(&1 in disabled))
  end

  @doc """
  The system definitions under `SecantServiceWeb.Systems.`, by module name:
  the application's modules there that declare the
  `SecantServiceWeb.SystemDefinition` behaviour.
  """
  def discovered do
    (Application.spec(:secant_service, :modules) || [])
    |> Enum.filter(&(String.starts_with?(Atom.to_string(&1), @namespace) and definition?(&1)))
    |> Enum.sort()
  end

  defp definition?(module) do
    Code.ensure_loaded?(module) and
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()
      |> Enum.member?(SecantServiceWeb.SystemDefinition)
  end

  @doc """
  The matched modules of `node`, as `%{module_name => match}`. `bindings`
  defaults to `SecantService.Systems.bindings(node)`.
  """
  def matches(node, bindings \\ nil) do
    bindings = bindings || Systems.bindings(node)

    case configured() do
      [] ->
        %{}

      systems ->
        modules = Map.new(node.modules || [], &{&1.name, &1})

        for {name, module_bindings} <- bindings,
            module = Map.get(modules, name),
            module != nil,
            match = match(module, module_bindings, systems),
            match != nil,
            into: %{},
            do: {name, match}
    end
  end

  @doc """
  The `{module_name, parameter_name}` pairs that matched cards show, which
  must reach the card's displays live.
  """
  def shown_parameters(matches) do
    for {module_name, match} <- matches,
        %{shown_parameters: names} <- [card(match)],
        name <- names,
        into: MapSet.new(),
        do: {module_name, name}
  end

  @doc "The custom card of a match, or nil."
  def card(nil), do: nil
  def card(%{role: role}), do: role.card()

  @doc "The custom module plot of a match, or nil."
  def plot(nil), do: nil
  def plot(%{role: role}), do: role.plot()

  defp match(module, bindings, systems) do
    params = MapSet.new(module.parameters || [], & &1.name)

    Enum.find_value(bindings, fn binding ->
      Enum.find_value(systems, &role_match(&1, binding, params))
    end)
  end

  defp role_match(system, binding, params) do
    with true <- system.system() == binding.system,
         true <- binding.version in system.versions(),
         role when not is_nil(role) <- Map.get(system.roles(binding.version), binding.role),
         true <- Enum.all?(role.required_parameters(), &MapSet.member?(params, &1)) do
      %{system: system, role: role, binding: binding}
    else
      _ -> nil
    end
  end
end
