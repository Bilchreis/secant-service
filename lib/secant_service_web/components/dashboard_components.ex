defmodule SecantServiceWeb.DashboardComponents do
  @moduledoc """
  Shared helpers of the node views: module grouping, ids, connection state.

  The components themselves are split by part of the page:
  `NodeTabs` (live node tabs and handshake), `NodeHeader`, `ModuleRail`,
  `ModuleGrid` (live cards) and `ModuleDetail` (inspector and data-browser
  panel). The live dashboard and the data browser share the header, the rail
  and the detail panel; the card grid is live only.

  Everything is rendered from the node's self-description, so none of these
  components may assume a particular module or parameter beyond what SECoP
  defines (`value`, `target`, `status`, `stop`, `go`).
  """
  alias SecantService.Util

  @doc """
  Groups modules by their SECoP `group` property, ungrouped modules last.
  Returns `[{label, modules}]`.
  """
  def group_modules(modules) do
    {ungrouped, grouped} =
      modules
      |> Enum.sort_by(&natural_key(&1.name))
      |> Enum.group_by(& &1.group)
      |> Map.pop(nil, [])

    grouped =
      grouped
      |> Enum.sort_by(fn {group, _} -> String.downcase(group) end)
      |> Enum.map(fn {group, mods} -> {Util.display_name(group), mods} end)

    case ungrouped do
      [] -> grouped
      mods -> grouped ++ [{if(grouped == [], do: nil, else: "Ungrouped"), mods}]
    end
  end

  # "contr10" sorts after "contr9"
  defp natural_key(name) do
    ~r/(\d+)/
    |> Regex.split(String.downcase(name), include_captures: true, trim: true)
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {n, ""} -> {0, n, ""}
        _ -> {1, 0, part}
      end
    end)
  end

  @doc "Groups parameters or commands by their SECoP `group`, ungrouped first."
  def group_accessibles(accessibles) do
    {ungrouped, grouped} =
      accessibles
      |> Enum.group_by(& &1.group)
      |> Map.pop(nil, [])

    grouped = Enum.sort_by(grouped, fn {group, _} -> String.downcase(group) end)

    case ungrouped do
      [] -> grouped
      items -> [{nil, items} | grouped]
    end
  end

  @doc false
  def class_label(nil), do: "module"
  def class_label(class), do: class

  def node_id_str(node), do: "#{node.host}:#{node.port}"

  @doc "DOM/component id of a card's sparkline; the dashboard routes plot data to it."
  # The uuid changes with the description; a new id makes LiveView start the
  # component from scratch instead of keeping state for the old description.
  def sparkline_id(node, module_name),
    do: "spark:#{node.uuid}:#{node.host}:#{node.port}:#{module_name}"

  @doc "Combined connection state: :initialized (live), :paused or the raw disconnected state."
  def conn_state(%{state: :initialized, active: false}), do: :paused
  def conn_state(%{state: state}), do: state
  def conn_state(_), do: :disconnected
end
