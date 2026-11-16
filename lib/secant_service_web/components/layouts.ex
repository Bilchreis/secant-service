defmodule SecantServiceWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use SecantServiceWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :active, :atom, default: nil, doc: "highlights a nav entry (:dashboard or :browse)"

  slot :inner_block, required: true
  slot :actions, doc: "extra buttons shown on the right of the top bar"

  def app(assigns) do
    ~H"""
    <header class="sticky top-0 z-30 border-b border-line bg-base-100/95 backdrop-blur">
      <div class="mx-auto flex max-w-[2560px] flex-wrap items-center gap-x-6 gap-y-2 px-4 py-2">
        <a href="/" class="flex items-center gap-2" id="home-link">
          <img src={~p"/images/logo.svg"} width="26" height="26" alt="" />
          <span class="text-[15px] font-bold tracking-wide">secant</span>
          <span class="font-mono text-[11px] text-muted">
            v{Application.spec(:secant_service, :vsn)}
          </span>
        </a>
        <nav class="flex items-center gap-1" aria-label="Main">
          <.link
            id="nav-dashboard"
            navigate={~p"/dashboard"}
            class={[
              "rounded-md px-3 py-1.5 text-sm font-medium transition-colors",
              if(@active == :dashboard,
                do: "bg-base-300 text-base-content",
                else: "text-muted hover:text-base-content hover:bg-base-300/60"
              )
            ]}
          >
            Dashboard
          </.link>
          <.link
            id="nav-browse"
            navigate={~p"/browse"}
            class={[
              "rounded-md px-3 py-1.5 text-sm font-medium transition-colors",
              if(@active == :browse,
                do: "bg-base-300 text-base-content",
                else: "text-muted hover:text-base-content hover:bg-base-300/60"
              )
            ]}
          >
            Data browser
          </.link>
        </nav>
        <div class="flex-1"></div>
        <div class="flex items-center gap-2">
          {render_slot(@actions)}
          <.theme_toggle />
        </div>
      </div>
    </header>

    <main class="mx-auto max-w-[2560px] px-4 py-4">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      class="relative flex flex-row items-center rounded-md border border-line bg-base-200"
      role="group"
      aria-label="Colour theme"
    >
      <div class="absolute left-0 h-full w-1/3 rounded-md border border-line bg-base-100 transition-[left] [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3" />

      <button
        class="relative flex w-1/3 cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="System theme"
        title="System theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="relative flex w-1/3 cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Light theme"
        title="Light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="relative flex w-1/3 cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Dark theme"
        title="Dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
