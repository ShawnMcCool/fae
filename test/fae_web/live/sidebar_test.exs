defmodule FaeWeb.SidebarTest do
  use FaeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FaeWeb.SidebarNav

  describe "SidebarNav.active?/2" do
    test "the home route is active only on an exact match" do
      assert SidebarNav.active?("/", "/")
      refute SidebarNav.active?("/backups", "/")
    end

    test "non-home items match prefixes" do
      assert SidebarNav.active?("/backups", "/backups")
      assert SidebarNav.active?("/backups/abc-uuid", "/backups")
      assert SidebarNav.active?("/backups/abc-uuid/edit", "/backups")
    end

    test "longer prefixes win when two items both match" do
      # /backups/destinations and /backups both prefix-match
      # /backups/destinations — only the more specific one lights up.
      refute SidebarNav.active?("/backups/destinations", "/backups")
      assert SidebarNav.active?("/backups/destinations", "/backups/destinations")
    end

    test "rejects partial-segment matches" do
      # /backups should NOT match /backups-archive (no path boundary).
      refute SidebarNav.active?("/backups-archive", "/backups")
    end

    test "nil current_path never matches" do
      refute SidebarNav.active?(nil, "/")
      refute SidebarNav.active?(nil, "/backups")
    end
  end

  describe "sidebar rendering" do
    test "renders the icon rail on the dashboard", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ ~s|data-role="sidebar"|
      # All three top-level nav targets appear as links.
      assert html =~ ~s|data-path="/"|
      assert html =~ ~s|data-path="/backups"|
      assert html =~ ~s|data-path="/backups/destinations"|
      assert html =~ ~s|data-path="/update"|
    end

    test "dashboard link is active on /", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ ~s|data-active="true" data-path="/"|
    end

    test "backup jobs link is active on /backups", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ ~s|data-active="true" data-path="/backups"|
      # Destinations should NOT be active when on the jobs index.
      refute html =~ ~s|data-active="true" data-path="/backups/destinations"|
    end

    test "destinations link is active on /backups/destinations, jobs is not", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/backups/destinations")
      assert html =~ ~s|data-active="true" data-path="/backups/destinations"|
      assert html =~ ~s|data-active="false" data-path="/backups"|
    end

    test "tooltips carry the human label", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ ~s|data-tip="Dashboard"|
      assert html =~ ~s|data-tip="Backup jobs"|
      assert html =~ ~s|data-tip="Destinations"|
      assert html =~ ~s|data-tip="Updates"|
    end
  end
end
