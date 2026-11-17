defmodule SecantServiceWeb.Components.DashParameter do
  @moduledoc """
  One parameter row in the module inspector of the live dashboard: name,
  type, access, description, live value and (when writable) a Set form.
  """
  use Phoenix.LiveComponent

  alias SecantServiceWeb.Components.ParameterValueDisplay
  alias SecantServiceWeb.ValueFormat
  import SecantServiceWeb.CoreComponents
  alias Phoenix.LiveView.JS

  @impl true
  def handle_event("show_graph", _params, socket) do
    send(self(), {:show_parameter_graph, socket.assigns.parameter})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:type_label, ValueFormat.type_label(assigns.parameter.datainfo))
      |> assign(:limits, ValueFormat.limits(assigns.parameter.datainfo))
      |> assign_new(:plotted, fn -> false end)

    ~H"""
    <div class="border-t border-line py-2.5 first:border-t-0" id={"param-row:" <> @id}>
      <div class="flex items-baseline gap-2">
        <span class="min-w-0 flex-1 font-mono text-[13px] font-semibold break-all">
          {@parameter.name}
        </span>
        <span class="font-mono text-xs text-muted" title={Jason.encode!(@parameter.datainfo)}>
          {@type_label}
        </span>
        <span class="rounded border border-line px-1 font-mono text-[11px] text-muted">
          {if @parameter.readonly, do: "r", else: "r/w"}
        </span>
        <button
          type="button"
          class={[
            "rounded p-0.5 transition-colors hover:bg-base-300",
            if(@plotted, do: "text-ink", else: "text-muted")
          ]}
          phx-click={JS.push("show_graph", target: @myself)}
          aria-label={"Plot history of #{@parameter.name}"}
          title="Plot history"
        >
          <.icon name="hero-chart-bar-micro" class="size-4" />
        </button>
      </div>
      <div :if={@parameter.description} class="mt-0.5 text-xs text-muted">
        {@parameter.description}
      </div>
      <div :if={@limits} class="font-mono text-xs text-muted">range {@limits}</div>
      <div class="mt-1.5">
        <.live_component
          module={ParameterValueDisplay}
          id={"parameter_value:" <> @node_id_str <> ":" <> @module_name <> ":" <> @parameter.name}
          class=""
          host={@host}
          port={@port}
          location="parameter_value"
          module_name={@module_name}
          parameter={@parameter}
          variant={:row}
          id_str={"parameter_value:" <> @node_id_str <> ":" <> @module_name <> ":" <> @parameter.name}
        />
      </div>
    </div>
    """
  end
end
