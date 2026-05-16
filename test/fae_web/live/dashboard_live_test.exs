defmodule FaeWeb.DashboardLiveTest do
  # async: false — DashboardLive subscribes to the system_status PubSub topic,
  # which is shared with any other test broadcasting on the same topic.
  use FaeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "GET /" do
    test "mounts and renders the system status panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#system-status")
    end

    test "updates the uptime display when SystemStatus broadcasts", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      Phoenix.PubSub.broadcast(
        Fae.PubSub,
        "system_status",
        {:system_status, %{boot_at: ~U[2026-05-16 12:00:00Z], uptime_seconds: 42}}
      )

      assert has_element?(view, "#uptime-seconds", "42")
    end
  end
end
