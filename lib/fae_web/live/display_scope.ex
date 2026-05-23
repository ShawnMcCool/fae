defmodule FaeWeb.DisplayScope do
  @moduledoc """
  LiveView `on_mount` hook that assigns `@timezone` to every LiveView in
  the default `live_session` and keeps it current.

  On the connected mount it subscribes to the `"settings"` topic and
  attaches a `:handle_info` hook so that changing the timezone (via
  `Fae.Display.put_timezone/1`) re-renders every open page in the new
  zone — satisfying the "LiveViews must be realtime" decision.

  Kept separate from `FaeWeb.SidebarScope` (which holds no persisted
  state). One cheap local-SQLite read per mount is acceptable;
  `Fae.Settings` is designed for direct reads.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  def on_mount(:default, _params, _session, socket) do
    socket = assign(socket, :timezone, Fae.Display.timezone())

    socket =
      if connected?(socket) do
        :ok = Fae.Settings.subscribe()
        attach_hook(socket, :display_timezone, :handle_info, &maybe_update_timezone/2)
      else
        socket
      end

    {:cont, socket}
  end

  defp maybe_update_timezone({:setting_changed, "display", _value}, socket) do
    {:halt, assign(socket, :timezone, Fae.Display.timezone())}
  end

  defp maybe_update_timezone(_message, socket), do: {:cont, socket}
end
