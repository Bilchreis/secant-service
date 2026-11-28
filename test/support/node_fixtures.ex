defmodule SecantService.NodeFixtures do
  @moduledoc """
  Builds SEC node states shaped like the ones `secant_client` produces and
  drives the node lifecycle (connect, description change, restart, removal)
  the way `secant_client` signals it to the service.
  """
  import ExUnit.Callbacks, only: [start_supervised!: 1, stop_supervised: 1]
  import ExUnit.Assertions

  alias SecantService.FakeNodeStatem
  alias SecantService.NodeManager

  @client_pubsub :secant_client_pubsub

  @status_datainfo %{
    type: "tuple",
    members: [
      %{type: "enum", members: %{IDLE: 100, WARN: 200, BUSY: 300, ERROR: 400}},
      %{type: "string"}
    ]
  }

  @doc "A unique node_id per test, so tests never share client tables or registry keys."
  def unique_node_id do
    {~c"127.0.0.1", 20_000 + System.unique_integer([:positive, :monotonic])}
  end

  @doc """
  A raw SECoP describe message (atom keys, like the parser decodes it).

  `modules` maps module names to parameter names, e.g.
  `%{"temp" => ["value", "status", "target"]}`. "status" gets a SECoP status
  datainfo, every other parameter is a double.
  """
  def raw_description(equipment_id, modules) do
    %{
      equipment_id: equipment_id,
      description: "test node #{equipment_id}",
      firmware: "test firmware",
      modules:
        Map.new(modules, fn {module, params} ->
          {String.to_atom(module),
           %{
             description: "module #{module}",
             interface_classes: ["Readable"],
             implementation: "test.#{module}",
             accessibles:
               Map.new(params, fn param ->
                 datainfo = if param == "status", do: @status_datainfo, else: %{type: "double"}

                 {String.to_atom(param),
                  %{datainfo: datainfo, readonly: param != "target", description: param}}
               end)
           }}
        end)
    }
  end

  @doc """
  Sets the node-level `systems` property (SECoP RFC-104) of a raw
  description, e.g. `%{mag5t_x: %{system: "PowerSupply:0", modules: %{current: "magcur_x"}}}`.
  """
  def put_systems(raw_description, systems), do: Map.put(raw_description, :systems, systems)

  @doc "The state a `SecantClient.NodeStatem` holds after a successful handshake."
  def node_state(node_id, raw_description, uuid \\ Ecto.UUID.generate()) do
    {host, port} = node_id

    %{
      host: host,
      port: port,
      node_id: node_id,
      pubsub_topic: topic(node_id),
      equipment_id: raw_description.equipment_id,
      reconnect_backoff: 5000,
      description:
        SecantClient.Parser.parse_node_description(raw_description, %{host: host, port: port}),
      raw_description: raw_description,
      active: true,
      uuid: uuid,
      error: false,
      state: :initialized,
      manual: false,
      last_seen_update_ts: nil,
      idn: nil
    }
  end

  def topic({host, port}), do: "#{host}:#{port}"

  @doc """
  A node appears in secant_client: its value table is filled, a (fake) state
  machine is registered and `:new_node` is broadcast. Returns the node state.
  """
  def connect_node(node_id, raw_description, opts \\ []) do
    seed_node_table(node_id, raw_description)
    state = node_state(node_id, raw_description)
    start_supervised!({FakeNodeStatem, {node_id, state, opts}})
    broadcast("new_node", {:new_node, topic(node_id), state})
    state
  end

  @doc """
  The node reconnects with a new description: secant_client issues a new uuid
  and broadcasts `:description_change`. Returns the new node state.
  """
  def change_description(node_id, raw_description, uuid \\ Ecto.UUID.generate()) do
    seed_node_table(node_id, raw_description)
    state = node_state(node_id, raw_description, uuid)
    FakeNodeStatem.put_state(node_id, state)
    broadcast("descriptive_data_change", {:description_change, topic(node_id), state})
    state
  end

  @doc "The state machine is gone from secant_client."
  def remove_node(node_id), do: stop_supervised({FakeNodeStatem, node_id})

  @doc """
  Fill the client's value table the way the parser does on value updates.
  The table belongs to the calling process, like it belongs to the state
  machine in production.
  """
  def seed_node_table(node_id, raw_description) do
    {:ok, table} = SecantClient.NodeTable.start(node_id)

    for {module, %{accessibles: accessibles}} <- raw_description.modules,
        {param, _} <- accessibles do
      value = if param == :status, do: [100, "idle"], else: 1.0
      :ets.insert(table, {{:data_report, module, param}, [value, %{t: 1_700_000_000.0}]})
    end

    table
  end

  def broadcast(topic, message), do: Phoenix.PubSub.broadcast(@client_pubsub, topic, message)

  @doc "Broadcast a value update like the parser does for an `update` message."
  def send_value_update({host, port}, module, param, data_report) do
    Phoenix.PubSub.broadcast(
      @client_pubsub,
      "value_update:#{host}:#{port}",
      {:value_update, module, param, data_report}
    )
  end

  @doc """
  Wait until the NodeManager has handled everything broadcast so far. PubSub
  delivers locally before `broadcast/3` returns, so a call queued after the
  broadcast is answered only once those messages are processed.
  """
  def flush_node_manager, do: :sys.get_state(NodeManager)

  @doc "Modules and their parameters as served by the running node services."
  def served_modules(node_id) do
    {:ok, {node_db, values}} = SecantService.NodeValues.get_snapshot(node_id)

    from_db =
      Map.new(node_db.modules, fn m ->
        {m.name, m.parameters |> Enum.map(& &1.name) |> Enum.sort()}
      end)

    from_values = Map.new(values, fn {m, params} -> {m, params |> Map.keys() |> Enum.sort()} end)
    assert from_db == from_values, "node description and values of the services disagree"
    from_db
  end

  def sorted(modules), do: Map.new(modules, fn {m, params} -> {m, Enum.sort(params)} end)

  @doc "Retry `fun` until it returns truthy (for work done in unlinked tasks)."
  def eventually(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("condition not met in time")
        else
          Process.sleep(20)
          do_eventually(fun, deadline)
        end
    end
  end
end
