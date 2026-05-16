defmodule FaeWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use FaeWeb, :html

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

  attr :current_path, :string,
    default: "/",
    doc: "the active path, used for sidebar highlight (set by FaeWeb.SidebarScope)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex min-h-screen">
      <.sidebar current_path={@current_path} />

      <div class="flex-1 flex flex-col min-w-0">
        <header class="navbar bg-base-100 border-b border-base-300 px-4 sm:px-6 lg:px-8">
          <div class="flex-1">
            <a href="/" class="flex w-fit items-baseline gap-2">
              <span class="text-lg font-semibold tracking-tight">Fae</span>
              <span class="text-xs opacity-60 font-mono">v{Fae.Version.current_version()}</span>
            </a>
          </div>
          <div class="flex-none">
            <.theme_toggle />
          </div>
        </header>

        <main class="px-4 py-10 sm:px-6 lg:px-8">
          <div class="mx-auto max-w-6xl space-y-4">
            {render_slot(@inner_block)}
          </div>
        </main>

        <.flash_group flash={@flash} />
      </div>
    </div>
    """
  end

  attr :current_path, :string, required: true

  defp sidebar(assigns) do
    ~H"""
    <aside
      class="flex flex-col w-14 shrink-0 bg-base-200 border-r border-base-300 sticky top-0 self-start h-screen"
      data-role="sidebar"
    >
      <nav class="flex flex-col items-center gap-1 py-3 flex-1">
        <%= for {group, idx} <- Enum.with_index(FaeWeb.SidebarNav.groups()) do %>
          <%= if idx > 0 do %>
            <div class="w-8 h-px bg-base-300 my-2" aria-hidden="true"></div>
          <% end %>
          <%= for item <- group.items do %>
            <.sidebar_item current_path={@current_path} item={item} />
          <% end %>
        <% end %>
      </nav>
    </aside>
    """
  end

  attr :current_path, :string, required: true
  attr :item, :map, required: true

  defp sidebar_item(assigns) do
    assigns =
      assign(
        assigns,
        :active?,
        FaeWeb.SidebarNav.active?(assigns.current_path, assigns.item.path)
      )

    ~H"""
    <div class="tooltip tooltip-right" data-tip={@item.label}>
      <.link
        navigate={@item.path}
        data-role="sidebar-item"
        data-path={@item.path}
        data-active={to_string(@active?)}
        class={[
          "flex items-center justify-center h-10 w-10 rounded-lg transition-colors",
          if(@active?,
            do: "bg-primary/10 text-primary",
            else: "text-base-content/70 hover:bg-base-300 hover:text-base-content"
          )
        ]}
      >
        <.icon name={@item.icon} class="size-5" />
      </.link>
    </div>
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
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
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
