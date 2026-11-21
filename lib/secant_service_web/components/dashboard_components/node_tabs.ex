defmodule SecantServiceWeb.DashboardComponents.NodeTabs do
  @moduledoc "Node tabs of the live dashboard and the connection handshake of a node that is not ready yet."
  use Phoenix.Component

  alias SecantService.Util

  import SecantServiceWeb.CoreComponents
  import SecantServiceWeb.SECoPComponents

  attr :active_nodes, :map, required: true
  attr :hidden_node_ids, :any, required: true
  attr :current_node_id, :any, default: nil, doc: "node_id of the node shown on the page"

  def node_tabs(assigns) do
    visible =
      assigns.active_nodes
      |> Enum.reject(fn {id, _} -> MapSet.member?(assigns.hidden_node_ids, id) end)
      |> Enum.sort_by(fn {_, n} -> n.equipment_id || n.pubsub_topic end)

    hidden =
      assigns.active_nodes
      |> Enum.filter(fn {id, _} -> MapSet.member?(assigns.hidden_node_ids, id) end)
      |> Enum.map(fn {_, n} -> n end)

    assigns = assign(assigns, visible: visible, hidden: hidden)

    ~H"""
    <nav id="node-tabs" class="flex flex-wrap items-center gap-2" aria-label="Nodes">
      <div :for={{_id, node} <- @visible} class="group relative">
        <button
          id={"node-tab-" <> node.pubsub_topic}
          phx-click="node-select"
          phx-value-pstopic={node.pubsub_topic}
          title={node_state_label(node.state, node.active)}
          class={[
            "flex min-h-11 items-center gap-2.5 rounded-lg border py-1.5 pr-8 pl-3 text-left transition-colors",
            if(node.node_id == @current_node_id,
              do: "border-primary bg-base-100",
              else: "border-line hover:bg-base-100"
            )
          ]}
        >
          <span class={["size-2.5 shrink-0 rounded-full", node_state_dot(node.state, node.active)]}></span>
          <span class="flex flex-col leading-tight">
            <span class="font-semibold">{display_node_name(node)}</span>
            <span class="font-mono text-[11px] text-muted">{node.pubsub_topic}</span>
          </span>
        </button>
        <button
          phx-click="toggle_hidden"
          phx-value-pstopic={node.pubsub_topic}
          class="absolute top-1/2 right-1.5 -translate-y-1/2 rounded p-1 text-muted opacity-0 transition-opacity group-hover:opacity-100 hover:bg-base-300 focus:opacity-100"
          title="Hide node"
          aria-label={"Hide #{display_node_name(node)}"}
        >
          <.icon name="hero-eye-slash-micro" class="size-4" />
        </button>
      </div>

      <div :if={@hidden != []} class="dropdown">
        <button
          tabindex="0"
          id="hidden-nodes-btn"
          class="flex min-h-11 items-center gap-2 rounded-lg border border-dashed border-line px-3 text-muted hover:bg-base-100"
        >
          <.icon name="hero-eye-slash-micro" class="size-4" /> {length(@hidden)} hidden
        </button>
        <div
          tabindex="0"
          class="dropdown-content z-40 mt-2 flex w-64 flex-col gap-1 rounded-box border border-line bg-base-100 p-2 shadow-xl"
        >
          <div
            :for={node <- @hidden}
            class="flex items-center justify-between gap-2 rounded px-2 py-1 hover:bg-base-200"
          >
            <span class="flex items-center gap-2 truncate">
              <span class={["size-2 rounded-full", node_state_dot(node.state, node.active)]}></span>
              {display_node_name(node)}
            </span>
            <button
              phx-click="toggle_hidden"
              phx-value-pstopic={node.pubsub_topic}
              class="rounded p-1 text-muted hover:bg-base-300"
              title="Show node"
              aria-label={"Show #{display_node_name(node)}"}
            >
              <.icon name="hero-eye-micro" class="size-4" />
            </button>
          </div>
        </div>
      </div>
    </nav>
    """
  end

  attr :node, :map, default: nil

  @doc """
  Shown instead of the node view while the selected node has no data: how far
  the handshake with the node got and where it hangs.
  """
  def node_unavailable(assigns) do
    assigns = assign(assigns, :steps, handshake_steps(assigns.node))

    ~H"""
    <div
      id="node-unavailable"
      role="status"
      class="flex flex-col gap-5 rounded-box border border-line bg-base-100 px-5 py-5 text-sm"
    >
      <div class="flex flex-col gap-1">
        <strong>
          No data from <span :if={@node} class="font-mono">{@node.pubsub_topic}</span>
          <span :if={!@node}>this node</span> yet.
        </strong>
        <span class="text-muted">
          The node shows up here once every step below is done.
        </span>
      </div>

      <ol id="handshake-steps" class="flex flex-col sm:flex-row">
        <li
          :for={step <- @steps}
          id={"handshake-step-#{step.id}"}
          data-status={step.status}
          class="group relative flex flex-1 gap-3 pb-5 last:pb-0 sm:flex-col sm:gap-2 sm:pr-5 sm:pb-0"
        >
          <%!-- the line to the next bobble: vertical on phones, horizontal from sm --%>
          <span
            aria-hidden="true"
            class={[
              "absolute top-5 bottom-0 left-2.5 w-0.5 -translate-x-1/2 transition-colors group-last:hidden",
              "sm:top-2.5 sm:right-0 sm:bottom-auto sm:left-5 sm:h-0.5 sm:w-auto sm:translate-x-0 sm:-translate-y-1/2",
              if(step.status == :done, do: "bg-st-idle", else: "bg-line")
            ]}
          ></span>
          <span class={[
            "relative z-10 flex size-5 shrink-0 items-center justify-center rounded-full border-2 bg-base-100 transition-colors",
            step_bobble_class(step.status)
          ]}>
            <.icon :if={step.status == :done} name="hero-check-micro" class="size-3.5" />
            <.icon :if={step.status == :failed} name="hero-x-mark-micro" class="size-3.5" />
            <span
              :if={step.status == :current}
              class="loading loading-spinner size-3 text-primary"
            ></span>
          </span>
          <div class="flex min-w-0 flex-col gap-0.5">
            <span class={[
              "leading-5 font-semibold",
              step.status == :pending && "text-muted",
              step.status == :failed && "text-st-error"
            ]}>
              {step.title}
            </span>
            <span class="text-xs text-muted">{step.detail}</span>
          </div>
        </li>
      </ol>
    </div>
    """
  end

  defp step_bobble_class(:done), do: "border-st-idle bg-st-idle text-base-100"
  defp step_bobble_class(:failed), do: "border-st-error bg-st-error text-base-100"
  defp step_bobble_class(:current), do: "border-primary"
  defp step_bobble_class(:pending), do: "border-line"

  @handshake_steps [
    connect: "Connect",
    identify: "Identify",
    describe: "Describe",
    record: "Record"
  ]

  @doc """
  The steps from finding a node to showing its data, each with a status:
  `:done`, `:current` (in progress), `:failed` (it hangs here) or `:pending`.

  `node` is the client's state of the node. A discovered node has a leading
  `:discover` step.
  """
  def handshake_steps(node) do
    {at, status, note} = handshake_position(node)
    ids = Keyword.keys(@handshake_steps)
    at_index = Enum.find_index(ids, &(&1 == at))

    steps =
      for {{id, title}, index} <- Enum.with_index(@handshake_steps) do
        cond do
          index < at_index ->
            %{id: id, title: title, status: :done, detail: step_done_detail(id, node)}

          index == at_index ->
            %{id: id, title: title, status: status, detail: note}

          true ->
            %{id: id, title: title, status: :pending, detail: step_pending_detail(id)}
        end
      end

    discover_step(node) ++ steps
  end

  # Nodes found by a discovery scan (not entered by hand) start one step earlier
  defp discover_step(%{manual: false}) do
    [
      %{
        id: :discover,
        title: "Discover",
        status: :done,
        detail: "The node answered a discovery scan."
      }
    ]
  end

  defp discover_step(_node), do: []

  # {step the node is at, status of that step, what is going on}
  defp handshake_position(%{state: :connecting}),
    do: {:connect, :current, "Opening the TCP connection."}

  defp handshake_position(%{state: :connected} = node) do
    if node[:idn],
      do: {:describe, :current, "Waiting for the node's description."},
      else: {:identify, :current, "Waiting for the answer to *IDN?."}
  end

  defp handshake_position(%{state: :could_not_initialize} = node) do
    if node[:idn],
      do: {:describe, :failed, "The node did not answer the describe request."},
      else: {:identify, :failed, "The node did not answer *IDN?."}
  end

  defp handshake_position(%{state: :initialized}),
    do: {:record, :current, "Storing the node and starting to record."}

  defp handshake_position(_node),
    do:
      {:connect, :failed, "The node does not accept the connection. Retrying every few seconds."}

  defp step_done_detail(:connect, _node), do: "TCP connection is open."

  defp step_done_detail(:identify, node) do
    case node[:idn] do
      %{version: version} when is_binary(version) -> "Speaks SECoP #{version}."
      _ -> "The node identified itself."
    end
  end

  defp step_done_detail(:describe, node) do
    case node[:equipment_id] do
      id when is_binary(id) -> "Description of #{Util.display_name(id)} received."
      _ -> "Description received."
    end
  end

  defp step_pending_detail(:identify), do: "Ask the node which SECoP version it speaks."
  defp step_pending_detail(:describe), do: "Read the node's modules and parameters."
  defp step_pending_detail(:record), do: "Store the node and start recording."

  defp display_node_name(%{equipment_id: id}) when is_binary(id), do: Util.display_name(id)

  defp display_node_name(%{uuid: uuid}) when is_binary(uuid),
    do: "node " <> String.slice(uuid, 0, 8)

  defp display_node_name(node), do: node.pubsub_topic
end
