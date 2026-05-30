defmodule FaeWeb.DotfilesLive.TrackPathComponentTest do
  use FaeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fae.Dotfiles.TrackedPaths

  # A tiny host LiveView so the LiveComponent has a parent process that
  # receives its {:track_done} / {:track_cancel} messages. We expose the
  # browser base + suggestion base via session so tests stay off the real
  # ~/.config. `tracked` lets a test pre-mark entries as tracked.
  defmodule Host do
    use FaeWeb, :live_view

    def mount(_params, session, socket) do
      {:ok,
       socket
       |> Phoenix.Component.assign(:base, session["base"])
       |> Phoenix.Component.assign(:tracked, session["tracked"] || [])
       |> Phoenix.Component.assign(:closed, false)}
    end

    def handle_info({:track_done}, socket),
      do: {:noreply, Phoenix.Component.assign(socket, :closed, true)}

    def handle_info({:track_cancel}, socket),
      do: {:noreply, Phoenix.Component.assign(socket, :closed, true)}

    def render(assigns) do
      ~H"""
      <div>
        <p :if={@closed} id="closed">closed</p>
        <.live_component
          module={FaeWeb.DotfilesLive.TrackPathComponent}
          id="track-path"
          tz="Etc/UTC"
          tracked_paths={@tracked}
          browse_root={@base}
          suggest_base={@base}
        />
      </div>
      """
    end
  end

  defp tmp_base do
    base = Path.join(System.tmp_dir!(), "track-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    base
  end

  defp render_host(conn, base, tracked \\ []) do
    live_isolated(conn, Host, session: %{"base" => base, "tracked" => tracked})
  end

  test "renders untracked suggestions as pills", %{conn: conn} do
    base = tmp_base()
    Enum.each(~w(alacritty kitty), &File.mkdir_p!(Path.join(base, &1)))

    {:ok, _view, html} = render_host(conn, base)

    assert html =~ "alacritty"
    assert html =~ "kitty"
  end

  test "selecting a suggestion and submitting adds a TrackedPath", %{conn: conn} do
    base = tmp_base()
    target = Path.join(base, "alacritty")
    File.mkdir_p!(target)

    {:ok, view, _html} = render_host(conn, base)

    view
    |> element(~s{button.badge[phx-click="toggle_select"][phx-value-path="#{target}"]})
    |> render_click()

    view
    |> element(~s{button[phx-click="submit"]})
    |> render_click()

    tracked = Enum.find(TrackedPaths.list(), &(&1.path == target))
    assert tracked
    assert tracked.kind == "directory"
    assert render(view) =~ "closed"
  end

  test "browser lists entries and disables already-tracked ones", %{conn: conn} do
    base = tmp_base()
    tracked_dir = Path.join(base, "nvim")
    free_dir = Path.join(base, "gtk-3.0")
    File.mkdir_p!(tracked_dir)
    File.mkdir_p!(free_dir)
    {:ok, _} = TrackedPaths.add(%{path: tracked_dir, kind: "directory"})

    {:ok, _view, html} = render_host(conn, base, [tracked_dir])

    assert html =~ "nvim"
    assert html =~ "gtk-3.0"
    # the already-tracked entry carries a "tracked" tag
    assert html =~ "tracked"
    # a tracked entry is not selectable via toggle_select
    refute html =~ ~s{phx-value-path="#{tracked_dir}"}
    # a free entry is selectable
    assert html =~ ~s{phx-value-path="#{free_dir}"}
  end

  test "navigating into a subfolder lists its entries", %{conn: conn} do
    base = tmp_base()
    sub = Path.join(base, "nested")
    File.mkdir_p!(Path.join(sub, "inner-thing"))

    {:ok, view, html} = render_host(conn, base)

    # the navigable folder is present at the base level
    assert html =~ "nested"

    new_html =
      view
      |> element(~s{button[phx-click="navigate"][phx-value-name="nested"]})
      |> render_click()

    assert new_html =~ "inner-thing"
  end

  test "manual add rejects a non-existent path", %{conn: conn} do
    base = tmp_base()
    {:ok, view, _html} = render_host(conn, base)

    bogus = Path.join(base, "does-not-exist")

    html =
      view
      |> element(~s{form[phx-submit="add_manual"]})
      |> render_submit(%{"path" => bogus})

    assert html =~ "does not exist"
    refute Enum.any?(TrackedPaths.list(), &(&1.path == bogus))
  end

  test "manual add accepts an existing path and submit tracks it", %{conn: conn} do
    base = tmp_base()
    real = Path.join(base, "real.conf")
    File.write!(real, "x")

    {:ok, view, _html} = render_host(conn, base)

    view
    |> element(~s{form[phx-submit="add_manual"]})
    |> render_submit(%{"path" => real})

    view
    |> element(~s{button[phx-click="submit"]})
    |> render_click()

    tracked = Enum.find(TrackedPaths.list(), &(&1.path == real))
    assert tracked
    assert tracked.kind == "file"
  end
end
