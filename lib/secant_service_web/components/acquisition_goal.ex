defmodule SecantServiceWeb.Components.AcquisitionGoal do
  @moduledoc """
  Progress of an acquisition channel towards its `goal`, the value that ends
  the acquisition cycle when reached. A disabled goal (`goal_enable` false)
  stays visible but greyed out. Values that are not plain numbers show the
  goal as text without a bar.

  The dashboard routes updates of `value`, `goal` and `goal_enable` here as
  `%{param: name, value_update: data_report}`.
  """
  use Phoenix.LiveComponent

  alias SecantClient.NodeTable
  alias SecantService.Acquisition
  alias SecantServiceWeb.ValueFormat

  @params ["value", "goal", "goal_enable"]

  @doc "Component id for a channel module; the dashboard routes updates to it."
  def id(node_id_str, module_name), do: "acq_goal:" <> node_id_str <> ":" <> module_name

  @impl true
  def update(%{param: param, value_update: %{data_report: [value, _qualifiers]}}, socket)
      when param in @params do
    {:ok, assign(socket, :values, Map.put(socket.assigns.values, param, value))}
  end

  def update(%{param: _, value_update: _}, socket), do: {:ok, socket}

  def update(%{host: host, port: port, channel: module} = assigns, socket) do
    node_id = {String.to_charlist(host), port}
    params = Map.new(@params, &{&1, Enum.find(module.parameters, fn p -> p.name == &1 end)})

    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:module_name, module.name)
      |> assign(:params, params)
      |> assign_new(:values, fn ->
        for {name, param} <- params, param != nil, into: %{} do
          {name, lookup(node_id, module.name, name)}
        end
      end)

    {:ok, socket}
  end

  defp lookup(node_id, module_name, param) do
    case NodeTable.lookup(
           {:service, node_id},
           {:data_report, String.to_existing_atom(module_name), String.to_existing_atom(param)}
         ) do
      {:ok, %{data_report: [value, _qualifiers]}} -> value
      _ -> nil
    end
  end

  @impl true
  def render(%{params: %{"goal" => nil}} = assigns) do
    ~H"""
    <div id={@id} class="hidden"></div>
    """
  end

  def render(assigns) do
    %{"value" => value, "goal" => goal} =
      Map.merge(%{"value" => nil, "goal" => nil}, assigns.values)

    goal_param = assigns.params["goal"]
    # without goal_enable the goal is always active
    enabled = assigns.params["goal_enable"] == nil or assigns.values["goal_enable"] != false

    assigns =
      assign(assigns,
        enabled: enabled,
        progress: Acquisition.goal_progress(value, goal, enabled),
        value_text: ValueFormat.short(value, (assigns.params["value"] || goal_param).datainfo),
        goal_text: ValueFormat.short(goal, goal_param.datainfo),
        unit: ValueFormat.unit(goal_param.datainfo)
      )

    ~H"""
    <div
      id={@id}
      class={["flex flex-col gap-1 text-xs", not @enabled && "opacity-60"]}
      data-progress={@progress && Float.round(@progress * 1.0, 3)}
      data-enabled={to_string(@enabled)}
      title={if @enabled, do: "Acquisition stops at this goal", else: "Goal disabled (goal_enable)"}
    >
      <div class="flex items-baseline gap-1.5 text-muted">
        <span class="font-semibold tracking-wider uppercase text-[10px]">Goal</span>
        <span class="min-w-0 flex-1 truncate text-right font-mono">
          <span :if={@progress}>{@value_text} / </span>{@goal_text}<span :if={@unit != ""}>{@unit}</span>
          <span :if={not @enabled}> · off</span>
        </span>
      </div>
      <div
        :if={@progress}
        class="h-1.5 overflow-hidden rounded-full bg-base-300"
        role="progressbar"
        aria-valuemin="0"
        aria-valuemax="100"
        aria-valuenow={round(@progress * 100)}
      >
        <div
          class="h-full rounded-full bg-st-busy transition-[width] duration-500"
          style={"width: #{Float.round(@progress * 100.0, 1)}%"}
        >
        </div>
      </div>
    </div>
    """
  end
end
