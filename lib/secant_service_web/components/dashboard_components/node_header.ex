defmodule SecantServiceWeb.DashboardComponents.NodeHeader do
  @moduledoc """
  Header of a node: name, description, connection state (live and
  historical), and the banner shown while its values are not live.
  """
  use Phoenix.Component

  alias SecantService.Util

  import SecantServiceWeb.CoreComponents
  import SecantServiceWeb.SECoPComponents
  import SecantServiceWeb.DashboardComponents

  attr :node, :map, required: true
  attr :state_map, :map, default: nil, doc: "live connection state; nil in the data browser"
  attr :status_counts, :list, default: []
  slot :extra

  def node_header(assigns) do
    ~H"""
    <section
      id="node-header"
      class="flex flex-wrap items-center gap-x-8 gap-y-3 rounded-box border border-line bg-base-100 px-4 py-3"
    >
      <div class="min-w-0 max-w-[36rem] flex-[0_1_auto]">
        <div class="flex flex-wrap items-center gap-2.5">
          <h1 class="text-xl font-bold tracking-tight">{Util.display_name(@node.equipment_id)}</h1>
          <.check_badge check_result={@node.check_result} />
          {render_slot(@extra)}
        </div>
        <p
          :if={@node.description}
          class="mt-0.5 whitespace-pre-line break-words text-muted"
          phx-no-format
        >{compact_text(@node.description)}</p>
        <div
          :if={@status_counts != []}
          class="mt-1.5 flex flex-wrap gap-x-4 gap-y-1 text-xs"
          id="status-summary"
        >
          <span :for={{label, class} <- @status_counts} class="inline-flex items-center gap-1.5">
            <span class={["size-2 rounded-full", class]}></span>{label}
          </span>
        </div>
      </div>

      <div class="flex shrink-0 flex-wrap gap-x-8 gap-y-1">
        <dl class="grid grid-cols-[auto_auto] gap-x-3 gap-y-0.5 text-xs">
          <dt class="text-muted">URI</dt>
          <dd class="font-mono">{node_id_str(@node)}</dd>
          <dt class="text-muted">UUID</dt>
          <dd
            class="cursor-pointer font-mono"
            id={"uuid-" <> to_string(@node.uuid)}
            phx-hook="CopyToClipboard"
            data-copy={@node.uuid}
            data-tip={@node.uuid}
            title="Click to copy"
          >
            {String.slice(to_string(@node.uuid), 0, 8)}…
          </dd>
        </dl>
        <dl class="grid grid-cols-[auto_auto] gap-x-3 gap-y-0.5 text-xs">
          <dt :if={@node.firmware} class="text-muted">Firmware</dt>
          <dd :if={@node.firmware}>{@node.firmware}</dd>
          <dt class="text-muted">{if @state_map, do: "Connected", else: "Recorded"}</dt>
          <dd class="tabular-nums">
            {@node.inserted_at
            |> DateTime.from_naive!("Etc/UTC")
            |> DateTime.shift_zone!("Europe/Berlin")
            |> Calendar.strftime("%d.%m.%Y %H:%M")}
          </dd>
        </dl>
      </div>

      <div class="flex flex-wrap items-center gap-2">
        <button
          :if={@state_map}
          id="live-updates-toggle"
          phx-click="toggle-conn-state"
          disabled={@state_map.state != :initialized}
          data-confirm={
            @state_map.active &&
              "Pause live updates for this node? This stops updates for every viewer and pauses recording until resumed."
          }
          aria-pressed={to_string(@state_map.active)}
          class="btn btn-sm gap-2 border-line bg-transparent font-normal"
          title="Asynchronous update messages from the node"
        >
          <span class={[
            "relative inline-block h-3.5 w-6 rounded-full transition-colors",
            if(@state_map.active, do: "bg-st-idle", else: "bg-st-off")
          ]}>
            <span class={[
              "absolute top-0.5 size-2.5 rounded-full bg-base-100 transition-all",
              if(@state_map.active, do: "right-0.5", else: "left-0.5")
            ]}></span>
          </span>
          {if @state_map.active, do: "Live updates", else: "Updates paused"}
        </button>
        <a
          :if={@node.ophyd_class}
          href={"data:text/x-python;base64,#{Base.encode64(@node.ophyd_class)}"}
          download={Util.display_name(@node.equipment_id) <> "_" <> String.slice(to_string(@node.uuid), 0, 8) <> ".py"}
          class="btn btn-sm border-line bg-transparent font-normal"
        >
          <.icon name="hero-arrow-down-tray-micro" class="size-4" /> ophyd class
        </a>
        <a
          id="nexus-export"
          href={"/export/node/#{@node.uuid}"}
          download
          class="btn btn-sm border-line bg-transparent font-normal"
          title="Download everything recorded for this node as a NeXus (HDF5) file"
        >
          <.icon name="hero-arrow-down-tray-micro" class="size-4" />
          <%!-- the purple of the NeXus logo; lightened on dark for contrast --%>
          <span class="font-semibold text-[#7a1192] dark:text-[#cf9be3]">NeXus</span>
        </a>
      </div>
    </section>
    """
  end

  attr :conn_state, :atom, required: true

  @doc "Warns that the values on screen are not live."
  def stale_banner(assigns) do
    ~H"""
    <div
      :if={@conn_state != :initialized}
      id="stale-banner"
      role="alert"
      class={[
        "flex items-center gap-2.5 rounded-box border px-4 py-2.5 text-sm",
        if(@conn_state == :paused,
          do: "border-st-busy/50 bg-st-busy/10",
          else: "border-st-error/50 bg-st-error/10"
        )
      ]}
    >
      <.icon
        name={if(@conn_state == :paused, do: "hero-pause-circle", else: "hero-signal-slash")}
        class={"size-5 shrink-0 " <> if(@conn_state == :paused, do: "text-st-busy", else: "text-st-error")}
      />
      <%= if @conn_state == :paused do %>
        <span>
          <strong>Live updates paused.</strong>
          Values below are the last received and are not updating; nothing is recorded while paused.
        </span>
      <% else %>
        <span>
          <strong>{if @conn_state == :connected,
            do: "Reconnecting to the node.",
            else: "Node disconnected."}</strong>
          Values below are the last received before the connection was lost and may be stale.
        </span>
      <% end %>
    </div>
    """
  end

  # descriptions often contain blank lines; keep line breaks, drop the gaps
  defp compact_text(text) do
    text
    |> String.trim()
    |> String.replace(~r/\n\s*\n+/, "\n")
  end
end
