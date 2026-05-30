defmodule FaeWeb.DotfilesLiveTest do
  use FaeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Fae.Dotfiles.{Configs, TrackedPaths}

  test "renders tracked paths and health", %{conn: conn} do
    {:ok, _} = Configs.update(%{enabled: true})
    home = System.tmp_dir!()
    File.mkdir_p!(Path.join(home, ".config/nvim"))
    {:ok, _} = TrackedPaths.add(%{path: Path.join(home, ".config/nvim"), kind: "directory"})
    {:ok, _view, html} = live(conn, ~p"/dotfiles")
    assert html =~ "Dotfiles"
    assert html =~ "nvim"
  end

  test "backup_now is wired", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/dotfiles")
    # Under Oban :inline, run_now executes synchronously against the configured tmp paths.
    # Wrap in manual mode so the click only enqueues (pure UI assertion), avoiding a real pipeline run.
    Oban.Testing.with_testing_mode(:manual, fn ->
      render_click(view, "backup_now", %{})
    end)

    assert render(view) =~ "Back up now"
  end
end
