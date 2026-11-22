defmodule SecantService.Generators do
  @moduledoc """
  Test data for the SecNodes resources, built with `Ash.Generator` through
  the resources' `:create` actions. Imported by `SecantService.DataCase` and
  `SecantServiceWeb.ConnCase`:

      node = generate(sec_node(host: "192.0.2.1"))
      parameter = generate(parameter(datainfo: %{"type" => "double"}))
      {node, parameter} = node_with_parameter(datainfo: %{"type" => "double"})

  Identity values (`uuid`, `equipment_id`) are unique per record, so tests
  can run concurrently without colliding. A module or parameter without a
  parent gets a new one; pass `sec_node_id:` / `module_id:` to use your own.

  Every other accepted attribute is its default (or nil) unless given. `Ash.Generator` would
  otherwise fill optional attributes with random values (it is built for
  property tests), and a random `describe_message_raw` or `description`
  changes what a test sees.
  """
  use Ash.Generator

  alias SecantService.SecNodes.{Module, Parameter, SecNode}

  def sec_node(opts \\ []) do
    changeset_generator(SecNode, :create,
      defaults:
        nil_defaults(SecNode,
          uuid: StreamData.repeatedly(&Ecto.UUID.generate/0),
          equipment_id:
            StreamData.repeatedly(fn -> "node_#{System.unique_integer([:positive])}" end),
          host: "localhost",
          port: 10_800
        ),
      overrides: opts
    )
  end

  def sec_module(opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :sec_node_id, fn -> generate(sec_node()).uuid end)

    changeset_generator(Module, :create,
      defaults: nil_defaults(Module, name: "m"),
      overrides: opts
    )
  end

  def parameter(opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :module_id, fn -> generate(sec_module()).id end)

    changeset_generator(Parameter, :create,
      defaults: nil_defaults(Parameter, name: "value", datainfo: %{"type" => "double"}),
      overrides: opts
    )
  end

  @doc """
  A node with one module holding one parameter, as `{node, parameter}`.
  `parameter_opts` go to the parameter, `node:` to the node.
  """
  def node_with_parameter(parameter_opts \\ []) do
    {node_opts, parameter_opts} = Keyword.pop(parameter_opts, :node, [])
    node = generate(sec_node(node_opts))
    module = generate(sec_module(sec_node_id: node.uuid))
    {node, generate(parameter(Keyword.put(parameter_opts, :module_id, module.id)))}
  end

  # `defaults`, plus every other attribute `:create` accepts at its own
  # default, or nil
  defp nil_defaults(resource, defaults) do
    resource
    |> Ash.Resource.Info.action(:create)
    |> Map.fetch!(:accept)
    |> Enum.reject(&Keyword.has_key?(defaults, &1))
    |> Enum.map(&{&1, static_default(Ash.Resource.Info.attribute(resource, &1))})
    |> Keyword.merge(defaults)
  end

  defp static_default(%{default: default}) when is_function(default), do: nil
  defp static_default(%{default: default}), do: default
end
