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

  test "ls_remote against a real local bare remote returns :ok" do
    remote = Path.join(System.tmp_dir!(), "remote-#{System.unique_integer([:positive])}.git")
    {_, 0} = System.cmd("git", ["init", "--bare", remote])
    on_exit(fn -> File.rm_rf!(remote) end)
    assert Git.ls_remote(remote) == :ok
  end

  test "ls_remote against a bogus path returns a classified error" do
    bogus =
      Path.join(System.tmp_dir!(), "no-such-remote-#{System.unique_integer([:positive])}.git")

    assert {:error, reason} = Git.ls_remote(bogus)
    assert reason in [:not_found, :auth_failed, :unreachable]
  end

  test "classify_remote_error: real not-found stderr (with auth tail) is :not_found" do
    out = "ERROR: Repository not found.\nfatal: Could not read from remote repository."
    assert Git.classify_remote_error(out) == :not_found
  end

  test "classify_remote_error: permission denied is :auth_failed" do
    out =
      "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository."

    assert Git.classify_remote_error(out) == :auth_failed
  end

  test "classify_remote_error: could not resolve host is :unreachable" do
    out = "ssh: Could not resolve host: github.com\nfatal: Could not read from remote repository."
    assert Git.classify_remote_error(out) == :unreachable
  end

  test "ensure_remote sets when missing, no-ops when same, updates when different",
       %{opts: opts} do
    remote_a = Path.join(System.tmp_dir!(), "ens-a-#{System.unique_integer([:positive])}.git")
    remote_b = Path.join(System.tmp_dir!(), "ens-b-#{System.unique_integer([:positive])}.git")

    # missing -> add
    refute remote_url("origin", opts)
    assert Git.ensure_remote("origin", remote_a, opts) == :ok
    assert remote_url("origin", opts) == remote_a

    # same -> no-op (still set to a)
    assert Git.ensure_remote("origin", remote_a, opts) == :ok
    assert remote_url("origin", opts) == remote_a

    # different -> set-url
    assert Git.ensure_remote("origin", remote_b, opts) == :ok
    assert remote_url("origin", opts) == remote_b
  end

  defp remote_url(name, opts) do
    case System.cmd(
           "git",
           [
             "--git-dir",
             opts[:git_dir],
             "--work-tree",
             opts[:work_tree],
             "remote",
             "get-url",
             name
           ],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end
end
