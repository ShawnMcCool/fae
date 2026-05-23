defmodule FaeWeb.DisplayScopeTest do
  # async: false — drives the shared "settings" PubSub topic + DB.
  use FaeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fae.Display

  test "dashboard timestamps render in the configured zone and update live", %{conn: conn} do
    {:ok, _} = Display.put_timezone("Europe/Amsterdam")

    {:ok, view, _html} = live(conn, ~p"/")
    # Amsterdam is always CET or CEST — proves @timezone reached <.local_datetime>.
    assert render(view) =~ ~r/CES?T/

    # Switching the zone broadcasts on "settings"; the open view re-renders in UTC.
    {:ok, _} = Display.put_timezone("UTC")
    rendered = render(view)
    assert rendered =~ " UTC"
    refute rendered =~ ~r/CES?T/
  end
end
