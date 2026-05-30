defmodule Fae.Dotfiles.Git do
  @moduledoc """
  Thin wrapper over `git` for a bare repo whose work-tree is `$HOME`.
  Functions accept `:git_dir`/`:work_tree` opts (default from `Paths`)
  and return tagged tuples — they never raise on nonzero git exit.
  """
  alias Fae.Dotfiles.Paths

  def init_bare(opts \\ []) do
    gd = git_dir(opts)
    File.mkdir_p!(Path.dirname(gd))

    case System.cmd("git", ["init", "--bare", gd], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  end

  def configure(opts \\ []) do
    with {_, 0} <- run(["config", "status.showUntrackedFiles", "no"], opts),
         {_, 0} <- run(["config", "user.name", "Fae"], opts),
         {_, 0} <- run(["config", "user.email", "fae@localhost"], opts) do
      :ok
    else
      {out, _} -> {:error, out}
    end
  end

  def set_remote(name, url, opts \\ []) do
    _ = run(["remote", "remove", name], opts)

    case run(["remote", "add", name, url], opts) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  end

  @doc "Write info/exclude from a list of gitignore-style patterns."
  def write_exclude(patterns, opts \\ []) do
    path = Path.join([git_dir(opts), "info", "exclude"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.join(patterns, "\n") <> "\n")
    :ok
  end

  def stage(roots, opts \\ []) do
    case run(["add", "-A", "--"] ++ roots, opts) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  end

  @doc "Parse `diff --cached --numstat` into a summary map."
  def staged_summary(opts \\ []) do
    {out, _} = run(["diff", "--cached", "--numstat"], opts)
    lines = out |> String.split("\n", trim: true)
    added = Enum.count(lines, &(String.starts_with?(&1, "0\t0\t") == false))
    # Per-file status counts come from --name-status:
    {st, _} = run(["diff", "--cached", "--name-status"], opts)
    statuses = st |> String.split("\n", trim: true) |> Enum.map(&String.first/1)

    %{
      files: length(lines),
      added: Enum.count(statuses, &(&1 == "A")),
      deleted: Enum.count(statuses, &(&1 == "D")),
      changed: Enum.count(statuses, &(&1 == "M")),
      _numstat_added: added
    }
  end

  def commit(message, opts \\ []) do
    case run(["commit", "-m", message], opts) do
      {_, 0} ->
        head_sha(opts)

      {out, _} ->
        if out =~ "nothing to commit", do: {:nochange}, else: {:error, out}
    end
  end

  def head_sha(opts \\ []) do
    case run(["rev-parse", "HEAD"], opts) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, out}
    end
  end

  def push(remote, branch, opts \\ []) do
    case run(["push", remote, "HEAD:#{branch}"], opts) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end

  def ahead_of_remote?(remote, branch, opts \\ []) do
    case run(["rev-list", "--count", "#{remote}/#{branch}..HEAD"], opts) do
      {out, 0} -> String.trim(out) != "0"
      _ -> true
    end
  end

  @doc "Scoped porcelain status for the given roots (modified/new/deleted)."
  def status(roots, opts \\ []) do
    {out, _} = run(["status", "--porcelain", "--untracked-files=all", "--"] ++ roots, opts)
    {:ok, String.split(out, "\n", trim: true)}
  end

  def ls_files(roots, opts \\ []) do
    case run(["ls-files", "--"] ++ roots, opts) do
      {out, 0} -> {:ok, String.split(out, "\n", trim: true)}
      {out, _} -> {:error, out}
    end
  end

  def rm_cached(roots, opts \\ []) do
    case run(["rm", "-r", "--cached", "--ignore-unmatch", "--"] ++ roots, opts) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  end

  def checkout(roots, opts \\ []) do
    case run(["checkout", "--"] ++ roots, opts) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  end

  defp run(args, opts) do
    System.cmd(
      "git",
      ["--git-dir", git_dir(opts), "--work-tree", work_tree(opts)] ++ args,
      env: [{"GIT_TERMINAL_PROMPT", "0"}],
      stderr_to_stdout: true
    )
  end

  defp git_dir(opts), do: Keyword.get(opts, :git_dir, Paths.git_dir())
  defp work_tree(opts), do: Keyword.get(opts, :work_tree, Paths.work_tree())
end
