defmodule FaeWeb.SettingsLiveTest do
  # async: false — writes go through the shared Fae.Settings table/topic.
  use FaeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fae.Display

  test "shows the current timezone", %{conn: conn} do
    {:ok, _} = Display.put_timezone("Europe/Amsterdam")
    {:ok, _view, html} = live(conn, ~p"/settings")
    assert html =~ ~s(id="current-timezone")
    assert html =~ "Europe/Amsterdam"
  end

  test "saving a zone via the form updates the preference", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#settings form", %{"timezone" => "America/New_York"})
    |> render_submit()

    assert Display.timezone() == "America/New_York"
    assert render(view) =~ "America/New_York"
  end

  test "a detected zone offers a one-click button that saves it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    # Simulate the JS hook pushing the browser's detected zone.
    render_hook(view, "timezone_detected", %{"timezone" => "Europe/Berlin"})
    assert render(view) =~ "Europe/Berlin"

    view |> element("#detected-row button") |> render_click()
    assert Display.timezone() == "Europe/Berlin"
  end

  test "an unknown detected zone offers no button", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    render_hook(view, "timezone_detected", %{"timezone" => "Mars/Phobos"})
    refute render(view) =~ ~s(id="detected-row")
  end

  test "the sidebar exposes a Settings link", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(data-path="/settings")
    assert html =~ ~s(data-tip="Settings")
  end
end
