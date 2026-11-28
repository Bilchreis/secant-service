defmodule SecantServiceWeb.Systems do
  @moduledoc """
  Matches a node's modules to the system definitions listed in
  `config :secant_service, :systems` (`SecantServiceWeb.SystemDefinition`).

  A module matches when one of its bindings (`SecantService.Systems`) has a
  configured system's name and one of its versions, that version has a role
  module (`SecantServiceWeb.SystemRole`) for the binding's role, and the
  module has every parameter the role requires. Bindings are tried in their
  order (by local system name), and system definitions in configuration
  order; the first full match wins.

  The config is read at call time, so tests can register systems with
  `Application.put_env/3`.
  """

  alias SecantService.Systems

  @type match :: %{system: module(), role: module(), binding: SecantService.Systems.Binding.t()}

  @doc "The configured system modules."
  def configured, do: Application.get_env(:secant_service, :systems, [])

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
