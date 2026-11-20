defmodule SecantService.DescribeMessageTransformer do
  alias SecantService.Util
  require Logger

  @moduledoc """
  Transforms SecantClient.NodeStatem state into database-ready format for Ash resources.
  Pure transformation logic with no database interaction.
  """

  @doc """
  Transforms a SecantClient.NodeStatem state into the format expected by SecNode Ash resource.

  ## Parameters
  - `statem_state` - The state map from SecantClient.NodeStatem containing:
    - `:host` - Host address
    - `:port` - Port number
    - `:equipment_id` - Equipment identifier
    - `:description` - Parsed description map
    - `:raw_description` - Raw JSON description string
    - `:uuid` - Optional UUID (will be generated if not provided)
    - Other metadata fields

  ## Returns
  Map ready for Ash.Changeset.for_create/2
  """
  def transform(statem_state) do
    description = statem_state[:description] || %{}
    properties = description[:properties] || %{}

    describe_str = Jason.encode!(statem_state[:raw_description])

    check_result = check_description(describe_str)

    ophyd_class =
      case ophyd_class(describe_str) do
        {:ok, class_str} -> class_str
        {:error, _} -> nil
      end

    ret = %{
      uuid: statem_state[:uuid] || Ash.UUID.generate(),
      equipment_id: statem_state[:equipment_id] || properties[:equipment_id],
      host: to_string(statem_state[:host]),
      port: statem_state[:port],
      description: properties[:description],
      firmware: properties[:firmware],
      implementor: properties[:implementor],
      timeout: properties[:timeout],
      describe_message: statem_state[:raw_description],
      describe_message_raw: describe_str,
      check_result: check_result,
      ophyd_class: ophyd_class,
      custom_properties: extract_custom_properties(properties),
      modules: transform_modules(description[:modules] || %{})
    }

    ret
  end

  defp transform_modules(modules_map) when is_map(modules_map) do
    Enum.map(modules_map, fn {module_name, module_data} ->
      parameters = module_data[:parameters] || %{}
      commands = module_data[:commands] || %{}
      properties = module_data[:properties] || %{}

      %{
        name: to_string(module_name),
        description: properties[:description],
        interface_classes: properties[:interface_classes] || [],
        highest_interface_class: Util.get_highest_if_class(properties[:interface_classes] || []),
        visibility: properties[:visibility] |> to_string(),
        group: properties[:group],
        meaning: properties[:meaning],
        implementor: properties[:implementation],
        custom_properties: extract_module_custom_properties(properties),
        parameters: transform_parameters(parameters),
        commands: transform_commands(commands)
      }
    end)
  end

  defp transform_parameters(parameters) when is_map(parameters) do
    parameters
    |> Enum.map(fn {param_name, param_data} ->
      %{
        name: to_string(param_name),
        datainfo: param_data[:datainfo],
        readonly: param_data[:readonly],
        description: param_data[:description],
        group: param_data[:group],
        visibility: param_data[:visibility] |> to_string(),
        meaning: param_data[:meaning],
        checkable: param_data[:checkable],
        custom_properties: extract_accessible_custom_properties(param_data)
      }
    end)
  end

  defp transform_commands(commands) when is_map(commands) do
    commands
    |> Enum.map(fn {cmd_name, cmd_data} ->
      datainfo = cmd_data[:datainfo] || %{}

      %{
        name: to_string(cmd_name),
        description: cmd_data[:description],
        datainfo: datainfo,
        argument: datainfo[:argument],
        result: datainfo[:result],
        group: cmd_data[:group],
        visibility: cmd_data[:visibility] |> to_string(),
        meaning: cmd_data[:meaning],
        checkable: cmd_data[:checkable],
        custom_properties: extract_accessible_custom_properties(cmd_data)
      }
    end)
  end

  # Extract custom properties (fields not part of standard SECoP spec)
  defp extract_custom_properties(properties) when is_map(properties) do
    standard_keys = [:description, :equipment_id, :firmware, :implementor, :timeout]

    properties
    |> Map.drop(standard_keys)
  end

  defp extract_module_custom_properties(properties) when is_map(properties) do
    standard_keys = [
      :commands,
      :parameters,
      :description,
      :features,
      :group,
      :implementation,
      :interface_classes,
      :visibility,
      :meaning
    ]

    properties
    |> Map.drop(standard_keys)
  end

  defp extract_accessible_custom_properties(accessible_data) when is_map(accessible_data) do
    standard_keys = [
      :datainfo,
      :description,
      :readonly,
      :group,
      :visibility,
      :meaning,
      :checkable
    ]

    accessible_data
    |> Map.drop(standard_keys)
  end

  defp ophyd_class(describe_str) do
    try do
      {result, _globals} =
        Pythonx.eval(
          """
          import json
          from secop_ophyd.GenNodeCode import GenNodeCode

          descr_str = descr.decode('utf-8') if isinstance(descr, bytes) else descr
          descr_dict = json.loads(descr_str)

          GenCode = GenNodeCode()

          GenCode.from_json_describe(json_data=descr_dict)

          GenCode.generate_code()

          """,
          %{"descr" => describe_str},
          stdout_device: File.open!("/dev/null", [:write]),
          stderr_device: File.open!("/dev/null", [:write])
        )

      class_str = Pythonx.decode(result)

      {:ok, class_str}
    rescue
      e in Pythonx.Error ->
        Logger.error("Python runtime error in ophyd_class gen: #{inspect(e)}")
        {:error, "could not generate ophyd-async class"}
    end
  end

  defp check_description(describe_str, version \\ "1.0", output \\ "json") do
    result =
      try do
        {result, _globals} =
          Pythonx.eval(
            """
            from secop_check.checker import Checker

            version_str = version.decode('utf-8') if isinstance(version, bytes) else str(version)
            output_str = output.decode('utf-8') if isinstance(output, bytes) else str(output)



            checker = Checker(version_str, [], output_str)

            checker.check(descr)


            diag_list = []

            for diag in checker.get_diags():
                step = f' [{diag.step}]' if diag.step else ''
                ctx = ' / '.join(f'{ty} {name}'.strip()
                                for ty, name in diag.ctx.path).strip()
                if ctx:
                    ctx += ': '

                diag_list.append({"severity": diag.severity.name,
                "step": diag.step,
                "message": diag.msg,
                "ctx": [ list(node) for node in diag.ctx.path],
                "text":f'{diag.severity.name}{step}: {ctx}{diag.msg}'
                })

            diag_list
            """,
            %{"descr" => describe_str, "version" => version, "output" => output},
            stdout_device: File.open!("/dev/null", [:write]),
            stderr_device: File.open!("/dev/null", [:write])
          )

        Pythonx.decode(result)
      rescue
        e in Pythonx.Error ->
          Logger.error("Python runtime error in check_description: #{inspect(e)}")

          [
            %{
              "severity" => "FATAL",
              "step" => "undefined",
              "message" => "SECoP Check Crashed",
              "ctx" => [],
              "text" => "SECoP Check Crashed"
            }
          ]
      end

    %{"version" => version, "result" => result}
  end
end
