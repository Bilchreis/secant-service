defmodule SecantService.Systems do
  @moduledoc """
  The SECoP systems (RFC-104) of a node, read from its `systems` node
  property into per-module bindings (`SecantService.Systems.Binding`).

  The property maps local system names to entries such as

      "mag5t_x": {"system": "PowerSupply:0", "description": "X axis",
                  "modules": {"current": "magcur_x", "voltage": "magvolt_x"}}

  A role whose value names a module of the node binds that module. A role
  whose value names another entry makes that entry a subsystem: its modules
  keep the binding of its own entry, which records the containing systems as
  parents.

  The property ends up in the node's custom properties, with string keys in
  the stored record (which the dashboard and the data browser both use) and
  atom keys straight from a description. The node controls its content, so
  everything here is total: malformed shapes are skipped, never raised on.
  """

  alias SecantService.Systems.Binding

  @doc """
  The bindings of every bound module of `node`, as
  `%{module_name => [Binding]}`, each list ordered by local system name.
  """
  def bindings(node) do
    module_names = node |> module_names() |> MapSet.new()
    entries = entries(node)
    local_names = MapSet.new(entries, & &1.local_name)

    {bound, edges} =
      Enum.reduce(entries, {[], []}, fn entry, acc ->
        Enum.reduce(entry.roles, acc, fn {role, value}, {bound, edges} ->
          cond do
            # a module name wins over a local system name (RFC-104 forbids
            # the clash)
            MapSet.member?(module_names, value) ->
              {[{entry, role, value} | bound], edges}

            MapSet.member?(local_names, value) and value != entry.local_name ->
              {bound, [{value, entry, role} | edges]}

            true ->
              {bound, edges}
          end
        end)
      end)

    containers =
      edges
      |> Enum.group_by(fn {inner, _outer, _role} -> inner end, fn {_, outer, role} ->
        {outer, role}
      end)
      |> Map.new(fn {inner, outers} ->
        {inner, Enum.sort_by(outers, fn {outer, role} -> {outer.local_name, role} end)}
      end)

    bound
    |> Enum.map(fn {entry, role, module} ->
      %Binding{
        local_name: entry.local_name,
        system: entry.system,
        version: entry.version,
        role: role,
        module: module,
        description: entry.description,
        parents: parents(entry.local_name, containers, MapSet.new([entry.local_name]))
      }
    end)
    |> Enum.group_by(& &1.module)
    |> Map.new(fn {module, list} -> {module, Enum.sort_by(list, &{&1.local_name, &1.role})} end)
  end

  @doc "The bindings of the module `module_name` of `node`, `[]` when it has none."
  def bindings_for(node, module_name), do: Map.get(bindings(node), module_name, [])

  @doc """
  Parses a system reference `Name:version`. RFC-104 defines no version
  syntax; this is the app's convention, borrowed from the schemas'
  `Name:version` references. Without a `:` the version is 0. Returns
  `{:ok, name, version}` or `:error`.
  """
  def parse_reference(reference) when is_binary(reference) do
    case String.split(reference, ":") do
      [name] ->
        if name == "", do: :error, else: {:ok, name, 0}

      parts ->
        {name_parts, [suffix]} = Enum.split(parts, -1)
        name = Enum.join(name_parts, ":")

        with true <- name != "",
             true <- Regex.match?(~r/\A\d+\z/, suffix),
             {version, ""} <- Integer.parse(suffix) do
          {:ok, name, version}
        else
          _ -> :error
        end
    end
  end

  def parse_reference(_), do: :error

  # The containing systems of `local_name`, innermost first. The first
  # container by local name is followed; a chain stops before revisiting an
  # entry.
  defp parents(local_name, containers, visited) do
    case Enum.find(Map.get(containers, local_name, []), fn {outer, _} ->
           not MapSet.member?(visited, outer.local_name)
         end) do
      nil ->
        []

      {outer, role} ->
        parent = %{
          local_name: outer.local_name,
          system: outer.system,
          version: outer.version,
          role: role
        }

        [parent | parents(outer.local_name, containers, MapSet.put(visited, outer.local_name))]
    end
  end

  defp module_names(%{modules: modules}) when is_list(modules) do
    for %{name: name} <- modules, is_binary(name), do: name
  end

  defp module_names(_), do: []

  # The valid entries of the node's `systems` property, as
  # `%{local_name:, system:, version:, description:, roles: [{role, value}]}`.
  defp entries(node) do
    case systems_property(node) do
      systems when is_map(systems) ->
        for {local_name, entry} <- systems,
            local_name = name_string(local_name),
            local_name != nil,
            parsed = parse_entry(local_name, entry),
            parsed != nil,
            do: parsed

      _ ->
        []
    end
  end

  defp systems_property(%{custom_properties: props}) when is_map(props),
    do: Map.get(props, "systems") || Map.get(props, :systems)

  defp systems_property(_), do: nil

  defp parse_entry(local_name, entry) when is_map(entry) do
    with {:ok, system, version} <- parse_reference(field(entry, "system", :system)),
         modules when is_map(modules) <- field(entry, "modules", :modules) do
      description =
        case field(entry, "description", :description) do
          d when is_binary(d) -> d
          _ -> nil
        end

      roles =
        for {role, value} <- modules,
            role = name_string(role),
            value = name_string(value),
            role != nil and value != nil,
            do: {role, value}

      %{
        local_name: local_name,
        system: system,
        version: version,
        description: description,
        roles: roles
      }
    else
      _ -> nil
    end
  end

  defp parse_entry(_local_name, _entry), do: nil

  defp field(map, key, atom_key), do: Map.get(map, key) || Map.get(map, atom_key)

  defp name_string(name) when is_binary(name), do: name

  defp name_string(name) when is_atom(name) and not is_nil(name) and not is_boolean(name),
    do: Atom.to_string(name)

  defp name_string(_), do: nil
end
