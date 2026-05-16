defmodule FaeWeb.SidebarScope do
  @moduledoc """
  LiveView `on_mount` hook that exposes `@current_path` on every
  LiveView so the sidebar can highlight the active item. Attaches a
  `handle_params` hook that re-assigns the path on every navigation
  (including `push_patch`).

  No persisted state — the sidebar is permanently collapsed and
  doesn't need a Settings round-trip.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:current_path, "/")
      |> attach_hook(:sidebar_current_path, :handle_params, &handle_params/3)

    {:cont, socket}
  end

  defp handle_params(_params, uri, socket) do
    path = URI.parse(uri).path || "/"
    {:cont, assign(socket, :current_path, path)}
  end
end
