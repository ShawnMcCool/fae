defmodule Fae.Dotfiles.ContextsTest do
  use Fae.DataCase, async: true
  alias Fae.Dotfiles.{Configs, TrackedPaths, Runs}

  test "Configs.get/0 creates the singleton then updates it" do
    c = Configs.get()
    assert c.id == 1 and c.enabled
    {:ok, c2} = Configs.update(%{interval_seconds: 1800})
    assert c2.interval_seconds == 1800
    assert Configs.get().interval_seconds == 1800
  end

  test "Configs.set_remote/2 with a reachable remote updates url, wires remote, broadcasts" do
    base = Path.join(System.tmp_dir!(), "cfgrem-#{System.unique_integer([:positive])}")
    gd = Path.join(base, "repo.git")
    remote = Path.join(base, "remote.git")
    File.mkdir_p!(base)
    {_, 0} = System.cmd("git", ["init", "--bare", remote])
    :ok = Fae.Dotfiles.Git.init_bare(git_dir: gd, work_tree: base)
    on_exit(fn -> File.rm_rf!(base) end)

    Phoenix.PubSub.subscribe(Fae.PubSub, Fae.Topics.dotfiles_status())

    {:ok, config} = Configs.set_remote(remote, git_dir: gd, work_tree: base)

    assert config.remote_url == remote
    assert config.last_push_ok
    assert config.last_push_error == nil
    assert_receive {:dotfiles_changed}

    {url, 0} = System.cmd("git", ["--git-dir", gd, "remote", "get-url", "origin"])
    assert String.trim(url) == remote
  end

  test "Configs.set_remote/2 with a bogus url returns error and leaves remote_url unchanged" do
    {:ok, _} = Configs.update(%{remote_url: "https://example.invalid/keep.git"})

    assert {:error, reason} =
             Configs.set_remote(
               "/definitely/not/a/repo-#{System.unique_integer([:positive])}.git"
             )

    assert reason in [:not_found, :unreachable, :auth_failed]
    assert Configs.get().remote_url == "https://example.invalid/keep.git"
  end

  test "TrackedPaths add/list/remove + broadcast" do
    Phoenix.PubSub.subscribe(Fae.PubSub, Fae.Topics.dotfiles_status())
    {:ok, tp} = TrackedPaths.add(%{path: "/home/x/.config/nvim", kind: "directory"})
    assert_receive {:dotfiles_changed}
    assert Enum.map(TrackedPaths.list(), & &1.path) == ["/home/x/.config/nvim"]
    :ok = TrackedPaths.remove(tp)
    assert TrackedPaths.list() == []
  end

  test "Runs lifecycle" do
    {:ok, run} = Runs.create_started()
    assert run.status == "running"

    {:ok, done} =
      Runs.finalize(run, %{
        status: "success",
        finished_at: DateTime.utc_now(),
        files_changed: 2,
        pushed: true
      })

    assert done.status == "success" and done.pushed
    assert [^done] = Runs.list_recent(5) |> Enum.filter(&(&1.id == done.id))
  end
end
