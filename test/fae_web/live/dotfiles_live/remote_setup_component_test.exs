defmodule FaeWeb.DotfilesLive.RemoteSetupComponentTest do
  use FaeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fae.Dotfiles.Configs

  # A host LiveView so the LiveComponent has a parent process that can
  # receive the {:remote_done} close message. The component's external
  # dependencies (gh availability, the gh "create repo" call, and the
  # Configs.set_remote validator) are injectable via assigns so tests
  # never hit the network or the real `gh` CLI. The paste path is driven
  # against a real *local* bare repo, which `Configs.set_remote` validates
  # with `git ls-remote` (no network needed).
  defmodule Host do
    use FaeWeb, :live_view

    # Function assigns (gh create fn, set_remote fn) cannot ride through the
    # serialized LiveView session token, so the test stashes the opts in
    # `:persistent_term` under a unique integer key and only that key travels
    # through the session.
    def mount(_params, session, socket) do
      opts = :persistent_term.get({__MODULE__, session["key"]}, %{})

      {:ok,
       socket
       |> Phoenix.Component.assign(:opts, opts)
       |> Phoenix.Component.assign(:done, false)}
    end

    def handle_info({:remote_done}, socket) do
      if pid = socket.assigns.opts[:test_pid], do: send(pid, {:host_remote_done})
      {:noreply, Phoenix.Component.assign(socket, :done, true)}
    end

    def render(assigns) do
      ~H"""
      <div>
        <p :if={@done} id="done">done</p>
        <.live_component
          module={FaeWeb.DotfilesLive.RemoteSetupComponent}
          id="remote-setup"
          github_available?={Map.get(@opts, :github_available?, false)}
          default_repo_name={Map.get(@opts, :default_repo_name, "dotfiles-test")}
          create_repo_fn={Map.get(@opts, :create_repo_fn, fn _ -> {:error, "boom"} end)}
          set_remote_fn={Map.get(@opts, :set_remote_fn, &Configs.set_remote/1)}
        />
      </div>
      """
    end
  end

  defp render_host(conn, opts) do
    key = System.unique_integer([:positive])
    :persistent_term.put({Host, key}, Map.put(opts, :test_pid, self()))
    on_exit(fn -> :persistent_term.erase({Host, key}) end)
    live_isolated(conn, Host, session: %{"key" => key})
  end

  # A real local bare *remote* repo that `git ls-remote` can reach with no
  # network. Returns the remote path plus a `set_remote_fn` that drives the
  # REAL `Configs.set_remote/2` against an isolated dotfiles bare repo, so
  # the paste path is exercised end-to-end without touching the live repo.
  defp bare_remote do
    base = Path.join(System.tmp_dir!(), "remote-#{System.unique_integer([:positive])}")
    git_dir = Path.join(base, "repo.git")
    remote = Path.join(base, "remote.git")
    File.mkdir_p!(base)
    {_, 0} = System.cmd("git", ["init", "--bare", remote], stderr_to_stdout: true)
    :ok = Fae.Dotfiles.Git.init_bare(git_dir: git_dir, work_tree: base)
    on_exit(fn -> File.rm_rf!(base) end)

    set_remote_fn = fn url ->
      Configs.set_remote(url, git_dir: git_dir, work_tree: base)
    end

    {remote, set_remote_fn}
  end

  describe "step 1 — choose" do
    test "shows the create-a-repo option with the default name when gh is available",
         %{conn: conn} do
      {:ok, _view, html} =
        render_host(conn, %{github_available?: true, default_repo_name: "dotfiles-box"})

      assert html =~ "Create a private GitHub repo"
      assert html =~ "dotfiles-box"
      assert html =~ "paste"
    end

    test "hides the create option and explains why when gh is unavailable", %{conn: conn} do
      {:ok, _view, html} = render_host(conn, %{github_available?: false})

      refute html =~ "Create a private GitHub repo"
      assert html =~ "GitHub CLI"
      assert html =~ "paste"
    end
  end

  describe "create path" do
    test "creating a repo wires the remote and reaches Done", %{conn: conn} do
      {remote, set_remote_fn} = bare_remote()

      opts = %{
        github_available?: true,
        default_repo_name: "dotfiles-box",
        # stub the gh create: pretend it created a repo whose ssh url is our
        # local bare repo, so the downstream set_remote validation succeeds.
        create_repo_fn: fn "dotfiles-box" -> {:ok, remote} end,
        set_remote_fn: set_remote_fn
      }

      {:ok, view, _html} = render_host(conn, opts)

      view |> element(~s{button[phx-click="choose_create"]}) |> render_click()

      html =
        view
        |> element(~s{form[phx-submit="create_repo"]})
        |> render_submit(%{"name" => "dotfiles-box"})

      assert html =~ "Remote set"
      assert html =~ remote
      assert Configs.get().remote_url == remote
    end

    test "an already-taken name shows a friendly inline error", %{conn: conn} do
      opts = %{
        github_available?: true,
        default_repo_name: "dotfiles-box",
        create_repo_fn: fn _ -> {:error, :already_exists} end
      }

      {:ok, view, _html} = render_host(conn, opts)

      view |> element(~s{button[phx-click="choose_create"]}) |> render_click()

      html =
        view
        |> element(~s{form[phx-submit="create_repo"]})
        |> render_submit(%{"name" => "taken"})

      assert html =~ "taken"
      # still on the create step, no Done yet
      refute html =~ "Remote set"
    end
  end

  describe "paste path" do
    test "pasting a reachable repo url saves it, finishes, and notifies the parent",
         %{conn: conn} do
      {remote, set_remote_fn} = bare_remote()

      {:ok, view, _html} =
        render_host(conn, %{github_available?: false, set_remote_fn: set_remote_fn})

      view |> element(~s{button[phx-click="choose_paste"]}) |> render_click()

      html =
        view
        |> element(~s{form[phx-submit="save_url"]})
        |> render_submit(%{"url" => remote})

      assert html =~ "Remote set"
      assert html =~ remote
      assert Configs.get().remote_url == remote

      # The Done step's Close button notifies the parent to dismiss the modal.
      view |> element(~s{button[phx-click="close"]}, "Close") |> render_click()
      assert_receive {:host_remote_done}
    end

    test "pasting a bogus url shows a friendly error and leaves the remote unchanged",
         %{conn: conn} do
      before = Configs.get().remote_url

      {:ok, view, _html} = render_host(conn, %{github_available?: false})

      view |> element(~s{button[phx-click="choose_paste"]}) |> render_click()

      html =
        view
        |> element(~s{form[phx-submit="save_url"]})
        |> render_submit(%{"url" => "/no/such/repo/here.git"})

      # A bogus local path is classified by git into one of the friendly
      # reasons; assert we show a friendly sentence (not a raw git fatal)
      # and stayed off the Done step.
      assert html =~ "found" or html =~ "reach" or html =~ "rejected the key"
      assert html =~ "alert-error"
      refute html =~ "Remote set"
      refute html =~ "fatal:"
      assert Configs.get().remote_url == before
    end
  end
end
