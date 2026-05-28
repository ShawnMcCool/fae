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

    test "destinations highlights across its own subtree, never another item" do
      assert SidebarNav.active?("/destinations", "/destinations")
      assert SidebarNav.active?("/destinations/new", "/destinations")
      assert SidebarNav.active?("/destinations/abc-uuid/edit", "/destinations")

      # Destinations and Backups are independent top-level routes now —
      # neither lights the other.
      refute SidebarNav.active?("/destinations", "/backups")
      refute SidebarNav.active?("/backups", "/destinations")
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

  describe "SidebarNav.groups/1" do
    defp paths_in(groups) do
      groups |> Enum.flat_map(& &1.items) |> Enum.map(& &1.path)
    end

    test "top groups carry the dashboard, tools, and shared destinations" do
      paths = paths_in(SidebarNav.groups(:top))
      assert "/" in paths
      assert "/backups" in paths
      assert "/archive" in paths
      assert "/destinations" in paths
      refute "/update" in paths
      refute "/settings" in paths
    end

    test "bottom groups are exactly the system chrome, in order" do
      assert paths_in(SidebarNav.groups(:bottom)) == ["/update", "/settings"]
    end
  end

  describe "sidebar rendering" do
    test "renders the icon rail with every nav target on the dashboard", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ ~s|data-role="sidebar"|

      for path <- ~w(/ /backups /archive /destinations /update /settings) do
        assert html =~ ~s|data-path="#{path}"|
      end
    end

    test "dashboard link is active on /", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ ~s|data-active="true" data-path="/"|
    end

    test "backup jobs link is active on /backups", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ ~s|data-active="true" data-path="/backups"|
      # Destinations should NOT be active when on the jobs index.
      refute html =~ ~s|data-active="true" data-path="/destinations"|
    end

    test "destinations link is active on /destinations, jobs is not", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/destinations")
      assert html =~ ~s|data-active="true" data-path="/destinations"|
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

  describe "rail zones" do
    defp in_zone?(view, zone, path) do
      has_element?(view, ~s|[data-role="#{zone}"] [data-path="#{path}"]|)
    end

    test "dashboard, tools, and destinations sit in the top zone", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for path <- ~w(/ /backups /archive /destinations) do
        assert in_zone?(view, "sidebar-top", path)
      end

      refute in_zone?(view, "sidebar-top", "/update")
      refute in_zone?(view, "sidebar-top", "/settings")
    end

    test "updates and settings are pinned to the bottom zone", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert in_zone?(view, "sidebar-bottom", "/update")
      assert in_zone?(view, "sidebar-bottom", "/settings")
      refute in_zone?(view, "sidebar-bottom", "/backups")
      refute in_zone?(view, "sidebar-bottom", "/destinations")
    end
  end

  describe "navbar (Phoenix-default chrome removed)" do
    test "shows the Fae brand and version, not Phoenix's", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Fae"
      assert html =~ "v#{Fae.Version.current_version()}"

      # Phoenix-default chrome must be gone.
      refute html =~ "phoenixframework.org"
      refute html =~ "Get Started"
      refute html =~ "hexdocs.pm/phoenix/overview"
    end

    test "page titles flow through per LiveView", %{conn: conn} do
      # HEEx renders <title> with whitespace around the interpolation,
      # so match the title block with a permissive regex rather than an
      # exact substring.
      title_re = fn label ->
        ~r{<title[^>]*>\s*#{Regex.escape(label)}\s*·\s*Fae\s*</title>}
      end

      {:ok, _, html_root} = live(conn, ~p"/")
      assert html_root =~ title_re.("Dashboard")

      {:ok, _, html_backups} = live(conn, ~p"/backups")
      assert html_backups =~ title_re.("Backup jobs")

      {:ok, _, html_destinations} = live(conn, ~p"/destinations")
      assert html_destinations =~ title_re.("Destinations")
    end
  end
end
