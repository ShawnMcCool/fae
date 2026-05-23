defmodule FaeWeb.DisplayScopeTest do
  # async: false — drives the shared "settings" PubSub topic + DB.
  use FaeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fae.Display

  test "the hook mounts cleanly and survives a timezone change broadcast", %{conn: conn} do
    {:ok, _} = Display.put_timezone("Europe/Amsterdam")

    {:ok, view, _html} = live(conn, ~p"/")
    assert render(view) =~ "Booted at"

    # Changing the zone broadcasts on "settings"; the attached handle_info
    # hook must update @timezone without crashing the view.
    {:ok, _} = Display.put_timezone("UTC")
    assert render(view) =~ "Booted at"
  end
end
