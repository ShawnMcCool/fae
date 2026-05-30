defmodule FaeWeb.DotfilesLive.IgnoresComponentTest do
  use FaeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fae.Dotfiles.{TrackedPath, TrackedPaths}
  alias Fae.Repo

  defmodule Host do
    use FaeWeb, :live_view

    def mount(_params, session, socket) do
      {:ok,
       socket
       |> Phoenix.Component.assign(:tracked_path, session["tracked_path"])
       |> Phoenix.Component.assign(:closed, false)}
    end

    def handle_info({:ignores_done}, socket),
      do: {:noreply, Phoenix.Component.assign(socket, :closed, true)}

    def render(assigns) do
      ~H"""
      <div>
        <p :if={@closed} id="closed">closed</p>
        <.live_component
          module={FaeWeb.DotfilesLive.IgnoresComponent}
          id="ignores"
          tracked_path={@tracked_path}
        />
      </div>
      """
    end
  end

  setup do
    {:ok, tp} =
      TrackedPaths.add(%{
        path: "/home/x/.config/nvim",
        kind: "directory",
        ignore_patterns: "node_modules\n*.log"
      })

    %{tp: tp}
  end

  test "pre-fills the textarea with existing patterns", %{conn: conn, tp: tp} do
    {:ok, _view, html} = live_isolated(conn, Host, session: %{"tracked_path" => tp})

    assert html =~ "node_modules"
    assert html =~ "*.log"
  end

  test "saving persists patterns via set_ignores and closes", %{conn: conn, tp: tp} do
    {:ok, view, _html} = live_isolated(conn, Host, session: %{"tracked_path" => tp})

    view
    |> element(~s{form[phx-submit="save"]})
    |> render_submit(%{"patterns" => "secrets/\n.env"})

    reloaded = Repo.get!(TrackedPath, tp.id)
    assert reloaded.ignore_patterns == "secrets/\n.env"
    assert render(view) =~ "closed"
  end
end
