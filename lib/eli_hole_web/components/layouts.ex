defmodule EliHoleWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use EliHoleWeb, :html

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
  attr :active_nav, :atom, default: nil, doc: "currently active nav item"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex min-h-screen">
      <aside class="hidden md:flex flex-col w-56 shrink-0 bg-base-200 border-r border-base-300">
        <div class="p-4 border-b border-base-300">
          <.link navigate={~p"/admin"} class="flex items-center gap-2">
            <.icon name="hero-shield-check" class="size-7 text-primary" />
            <span class="text-lg font-bold tracking-tight">EliHole</span>
          </.link>
          <p class="text-xs opacity-50 mt-0.5">DNS Sinkhole</p>
        </div>

        <nav class="flex-1 p-3 space-y-1">
          <.nav_item
            href={~p"/admin"}
            icon="hero-chart-bar"
            label="Dashboard"
            active={@active_nav == :dashboard}
          />
          <.nav_item
            href={~p"/admin/queries"}
            icon="hero-list-bullet"
            label="Query Log"
            active={@active_nav == :queries}
          />
          <.nav_item
            href={~p"/admin/blocklist"}
            icon="hero-shield-exclamation"
            label="Blocklist"
            active={@active_nav == :blocklist}
          />
          <.nav_item
            href={~p"/admin/gravity"}
            icon="hero-cloud-arrow-down"
            label="Gravity"
            active={@active_nav == :gravity}
          />
          <.nav_item
            href={~p"/admin/local-dns"}
            icon="hero-map-pin"
            label="Local DNS"
            active={@active_nav == :local_dns}
          />
          <.nav_item
            href={~p"/admin/settings"}
            icon="hero-cog-6-tooth"
            label="Settings"
            active={@active_nav == :settings}
          />
        </nav>

        <div class="p-3 border-t border-base-300 space-y-3">
          <.theme_toggle />
          <.link
            href={~p"/logout"}
            method="delete"
            class="flex items-center gap-2 text-sm opacity-60 hover:opacity-100 transition-opacity px-2"
          >
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" /> Logout
          </.link>
        </div>
      </aside>

      <div class="flex-1 flex flex-col min-w-0">
        <header class="md:hidden flex items-center justify-between px-4 py-3 bg-base-200 border-b border-base-300">
          <div class="flex items-center gap-2">
            <.icon name="hero-shield-check" class="size-6 text-primary" />
            <span class="font-bold">EliHole</span>
          </div>
          <div class="flex items-center gap-2">
            <.link navigate={~p"/admin"} class="btn btn-ghost btn-sm">
              <.icon name="hero-chart-bar" class="size-4" />
            </.link>
            <.link navigate={~p"/admin/queries"} class="btn btn-ghost btn-sm">
              <.icon name="hero-list-bullet" class="size-4" />
            </.link>
            <.link navigate={~p"/admin/blocklist"} class="btn btn-ghost btn-sm">
              <.icon name="hero-shield-exclamation" class="size-4" />
            </.link>
            <.link navigate={~p"/admin/gravity"} class="btn btn-ghost btn-sm">
              <.icon name="hero-cloud-arrow-down" class="size-4" />
            </.link>
            <.link navigate={~p"/admin/local-dns"} class="btn btn-ghost btn-sm">
              <.icon name="hero-map-pin" class="size-4" />
            </.link>
            <.link navigate={~p"/admin/settings"} class="btn btn-ghost btn-sm">
              <.icon name="hero-cog-6-tooth" class="size-4" />
            </.link>
          </div>
        </header>

        <main class="flex-1 p-4 sm:p-6 overflow-auto">
          <div class="mx-auto max-w-6xl">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp nav_item(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={[
        "flex items-center gap-3 px-3 py-2 rounded-lg text-sm font-medium transition-colors",
        if(@active,
          do: "bg-primary text-primary-content",
          else: "hover:bg-base-300 opacity-70 hover:opacity-100"
        )
      ]}
    >
      <.icon name={@icon} class="size-5" />
      {@label}
    </.link>
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
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
