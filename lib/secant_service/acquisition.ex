defmodule SecantService.Acquisition do
  @moduledoc """
  Ties an `AcquisitionController` to its `AcquisitionChannel` modules.

  The controller's `acquisition_channels` property maps a role (the key, e.g.
  `"t"` for the time channel) to a channel module name. The property ends up
  in the module's custom properties, with string keys when loaded from the
  database and atom keys straight from a description.
  """

  @doc "True for a module whose interface classes include AcquisitionController."
  def controller?(%{interface_classes: classes}) when is_list(classes),
    do: "AcquisitionController" in classes

  def controller?(_), do: false

  @doc """
  The channels of `controller` as `[{role, channel_name, module_or_nil}]`, the
  `t` role first and the rest by role. `module_or_nil` is the channel module
  from `modules`, or nil if the node has no module of that name.
  """
  def channels(controller, modules) do
    by_name = Map.new(modules, &{&1.name, &1})

    controller
    |> channel_map()
    |> Enum.map(fn {role, name} -> {role, name, Map.get(by_name, name)} end)
    |> Enum.sort_by(fn {role, _, _} -> {role != "t", role} end)
  end

  @doc "Names of all modules that some controller in `modules` claims as a channel."
  def channel_names(modules) do
    names = MapSet.new(modules, & &1.name)

    for module <- modules,
        controller?(module),
        {_role, name} <- channel_map(module),
        MapSet.member?(names, name),
        into: MapSet.new(),
        do: name
  end

  @doc """
  The controller of `module` among `modules` and the role it has there, as
  `{controller, role}`, or nil when no controller claims it.
  """
  def controller_of(%{name: name}, modules) do
    Enum.find_value(modules, fn module ->
      if controller?(module) do
        Enum.find_value(channel_map(module), fn
          {role, ^name} -> {module, role}
          _ -> nil
        end)
      end
    end)
  end

  defp channel_map(%{custom_properties: props}) when is_map(props) do
    case Map.get(props, "acquisition_channels") || Map.get(props, :acquisition_channels) do
      channels when is_map(channels) ->
        for {role, name} <- channels,
            is_binary(name) or is_atom(name),
            do: {to_string(role), to_string(name)}

      _ ->
        []
    end
  end

  defp channel_map(_), do: []

  @doc """
  How far a channel is towards its `goal`, as a float in 0..1, or nil when
  there is nothing to show: the goal is disabled, a value is missing, or
  either one is not a plain number. A goal of 0 or less has no progress.
  """
  def goal_progress(value, goal, goal_enable \\ true)

  def goal_progress(value, goal, goal_enable)
      when is_number(value) and is_number(goal) and goal > 0 and goal_enable != false,
      do: value |> Kernel./(goal) |> max(0.0) |> min(1.0)

  def goal_progress(_, _, _), do: nil
end
