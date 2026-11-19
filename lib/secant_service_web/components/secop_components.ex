defmodule SecantServiceWeb.SECoPComponents do
  @moduledoc """
  Small building blocks shared by the live dashboard and the data browser:
  status colours, the SECoP conformance badge, property lists and the
  connect-node form.
  """
  use Phoenix.Component

  alias SecantService.Util
  import SecantServiceWeb.CoreComponents
  alias Phoenix.LiveView.JS

  @doc "Background class for a SECoP status range (see `NodeValues.stat_code_to_color/1`)."
  def status_to_color(status) do
    case status do
      :disabled -> "bg-st-off"
      :idle -> "bg-st-idle"
      :warning -> "bg-st-warn"
      :busy -> "bg-st-busy"
      :error -> "bg-st-error"
      _ -> "bg-st-off"
    end
  end

  @doc "Text class for a SECoP status range."
  def status_to_text(status) do
    case status do
      :disabled -> "text-st-off"
      :idle -> "text-st-idle"
      :warning -> "text-st-warn"
      :busy -> "text-st-busy"
      :error -> "text-st-error"
      _ -> "text-st-off"
    end
  end

  @doc "Dot class for a node connection state."
  def node_state_dot(state, active) do
    case {state, active} do
      {:initialized, true} -> "bg-st-idle"
      {:initialized, _} -> "bg-st-busy"
      {:connected, _} -> "bg-st-busy"
      {:disconnected, _} -> "bg-st-error"
      _ -> "bg-st-off"
    end
  end

  def node_state_label(state, active) do
    case {state, active} do
      {:initialized, true} -> "connected, live updates on"
      {:initialized, _} -> "connected, live updates paused"
      {:connected, _} -> "connected, waiting for description"
      {:disconnected, _} -> "disconnected"
      _ -> to_string(state)
    end
  end

  defp severity_rank(severity) do
    case severity do
      "FATAL" -> 5
      "CATASTROPHIC" -> 4
      "ERROR" -> 3
      "WARNING" -> 2
      "HINT" -> 1
      "PASS" -> 0
      _ -> 5
    end
  end

  defp severity_class(severity) when severity in ["FATAL", "CATASTROPHIC", "ERROR"],
    do: "border-st-error text-st-error"

  defp severity_class("WARNING"), do: "border-st-warn text-st-warn"
  defp severity_class("HINT"), do: "border-line text-muted"
  defp severity_class(_), do: "border-st-idle text-st-idle"

  attr :check_result, :map, required: true
  attr :id, :string, default: "secop-check"

  @doc "SECoP conformance-check badge with the full result list in a dropdown."
  def check_badge(assigns) do
    result_list = Map.get(assigns.check_result || %{}, "result", [])

    severity_counts =
      result_list
      |> Enum.frequencies_by(& &1["severity"])
      |> Enum.sort_by(fn {severity, _count} -> severity_rank(severity) end, :desc)

    worst =
      case severity_counts do
        [] -> "PASS"
        [{severity, _} | _] -> severity
      end

    summary =
      case severity_counts do
        [] ->
          "SECoP check passed"

        counts ->
          "SECoP check: " <>
            Enum.map_join(counts, " · ", fn {s, c} -> "#{c} #{String.downcase(s)}" end)
      end

    assigns =
      assigns
      |> assign(:result_list, result_list)
      |> assign(:worst, worst)
      |> assign(:summary, summary)

    ~H"""
    <div class="dropdown">
      <button
        id={@id}
        type="button"
        tabindex="0"
        title="Conformance of the node's self-description to the SECoP standard (not a hardware status)"
        class="inline-flex h-6 items-center gap-1.5 rounded-full border border-line px-2.5 text-[11px] font-medium text-muted transition-colors hover:bg-base-300"
      >
        <span class={["size-1.5 rounded-full border-2", severity_class(@worst)]}></span>
        {@summary}
      </button>
      <div
        tabindex="0"
        class="dropdown-content z-40 mt-2 max-h-96 w-[44rem] max-w-[85vw] overflow-y-auto rounded-box border border-line bg-base-100 p-3 shadow-xl"
      >
        <div class="mb-2 text-xs text-muted">
          Checked against SECoP v{@check_result["version"]}
        </div>
        <ul :if={@result_list != []} class="flex flex-col gap-1 text-sm">
          <li
            :for={diag <- @result_list}
            class={["rounded-md border-l-4 bg-base-200 px-2 py-1", severity_class(diag["severity"])]}
          >
            <span class="mr-1 font-mono text-[11px]">{diag["severity"]}</span>
            <span class="text-base-content">{diag["text"]}</span>
          </li>
        </ul>
        <div :if={@result_list == []} class="text-sm">No issues found.</div>
      </div>
    </div>
    """
  end

  attr :prop_key, :string, required: true
  attr :class, :any, default: nil
  attr :key_class, :any, default: nil
  attr :value_class, :any, default: nil
  slot :inner_block, required: true

  @doc "One key/value row of a property list (`<dl>`)."
  def property(assigns) do
    ~H"""
    <div class={["flex justify-between gap-4 border-t border-line py-1.5 first:border-t-0", @class]}>
      <dt class={["shrink-0 text-muted", @key_class]}>{@prop_key}</dt>
      <dd class={["min-w-0 text-right break-words", @value_class]}>{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  @doc "Renders custom (`_`-prefixed) properties as property rows."
  attr :properties, :map, default: %{}

  def custom_properties(assigns) do
    ~H"""
    <.property
      :for={{name, value} <- @properties || %{}}
      prop_key={String.replace_prefix(name, "_", "")}
      value_class="font-mono text-xs"
    >
      {Util.short_inspect(value)}
    </.property>
    """
  end

  attr :id, :string, default: "connect-node", doc: "prefix for the ids, unique per instance"

  def connect_node(assigns) do
    ~H"""
    <div class="rounded-box border border-line bg-base-100 p-5">
      <h3 class="text-base font-semibold">Connect to a SEC node</h3>
      <p class="mt-1 text-muted">
        Nodes on the local network are found automatically. Enter host and port to connect to any other node.
      </p>

      <form
        phx-submit="connect-node"
        id={@id <> "-form"}
        class="mt-4 flex flex-wrap items-end gap-3"
      >
        <label class="flex flex-col gap-1">
          <span class="text-xs text-muted">Host</span>
          <input
            type="text"
            id={@id <> "-host"}
            name="host"
            placeholder="localhost"
            required
            class="input input-sm w-56 font-mono"
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-xs text-muted">Port</span>
          <input
            type="number"
            id={@id <> "-port"}
            name="port"
            placeholder="10767"
            required
            min="1"
            max="65535"
            class="input input-sm w-28 font-mono"
          />
        </label>
        <button
          type="button"
          phx-click={JS.dispatch("myapp:close-modal")}
          class="btn btn-sm btn-ghost"
        >
          Cancel
        </button>
        <button type="submit" class="btn btn-sm btn-primary">
          <.icon name="hero-link-micro" class="size-4" /> Connect
        </button>
      </form>
    </div>
    """
  end
end
