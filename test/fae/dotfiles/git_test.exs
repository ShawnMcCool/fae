defmodule Fae.Dotfiles.GitTest do
  use ExUnit.Case, async: true
  alias Fae.Dotfiles.Git

  setup do
    base = Path.join(System.tmp_dir!(), "git-test-#{System.unique_integer([:positive])}")
    work = Path.join(base, "home")
    git_dir = Path.join(base, "repo.git")
    File.mkdir_p!(work)
    opts = [git_dir: git_dir, work_tree: work]
    :ok = Git.init_bare(opts)
    :ok = Git.configure(opts)
    on_exit(fn -> File.rm_rf!(base) end)
    %{opts: opts, work: work}
  end

  test "stage + commit a new file, head_sha present", %{opts: opts, work: work} do
    File.mkdir_p!(Path.join(work, ".config/app"))
    File.write!(Path.join(work, ".config/app/conf"), "hello")
    :ok = Git.stage([".config/app"], opts)
    summary = Git.staged_summary(opts)
    assert summary.files == 1 and summary.added == 1
    {:ok, sha} = Git.commit("first", opts)
    assert is_binary(sha) and byte_size(sha) >= 7
    assert Git.head_sha(opts) == {:ok, sha}
  end

  test "commit with nothing staged returns :nochange", %{opts: opts} do
    assert Git.commit("noop", opts) == {:nochange}
  end

  test "rm_cached untracks but leaves the file on disk", %{opts: opts, work: work} do
    p = Path.join(work, "file.txt")
    File.write!(p, "x")
    :ok = Git.stage(["file.txt"], opts)
    {:ok, _} = Git.commit("add", opts)
    :ok = Git.rm_cached(["file.txt"], opts)
    {:ok, _} = Git.commit("untrack", opts)
    assert File.exists?(p)
    assert Git.ls_files(["file.txt"], opts) == {:ok, []}
  end

  test "push to a local bare remote, ahead detection", %{opts: opts, work: work} do
    remote = Path.join(System.tmp_dir!(), "remote-#{System.unique_integer([:positive])}.git")
    {_, 0} = System.cmd("git", ["init", "--bare", remote])
    on_exit(fn -> File.rm_rf!(remote) end)
    :ok = Git.set_remote("origin", remote, opts)
    File.write!(Path.join(work, "a"), "1")
    :ok = Git.stage(["a"], opts)
    {:ok, _} = Git.commit("c1", opts)
    assert Git.push("origin", "main", opts) == :ok
    refute Git.ahead_of_remote?("origin", "main", opts)
  end
end
