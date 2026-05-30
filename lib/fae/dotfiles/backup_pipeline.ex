defmodule Fae.Dotfiles.BackupPipeline do
  @moduledoc "Runs one dotfiles backup cycle and records the result."
  require Logger
  alias Fae.Dotfiles.{Configs, Git, PackageList, Paths, Runs, TrackedPaths}
  alias Fae.{Clock, Topics}

  @spec run(keyword()) :: {:ok, Fae.Dotfiles.Run.t()} | {:error, term()}
  def run(o \\ []) do
    git_opts = Keyword.get(o, :opts, [])
    pkg = Keyword.get(o, :package_cmd, &System.cmd/3)
    config = Configs.get()
    {:ok, run} = Runs.create_started()
    broadcast_run({:run_started, run.id})

    tracked = TrackedPaths.list()
    roots = Enum.map(tracked, & &1.path)
    manifest = manifest_path(git_opts)

    PackageList.write!(manifest, pkg)
    Git.write_exclude(collect_ignores(tracked), git_opts)

    case Git.stage(roots ++ [manifest_relpath(git_opts)], git_opts) do
      :ok -> finalize_after_stage(run, config, roots, git_opts)
      {:error, err} -> finalize_error(run, err)
    end
  end

  defp finalize_after_stage(run, config, roots, git_opts) do
    summary = Git.staged_summary(git_opts)
    now = Clock.now()

    if summary.files == 0 and
         not Git.ahead_of_remote?(config.remote_name, config.branch, git_opts) do
      {:ok, done} = Runs.finalize(run, %{status: "no_changes", finished_at: now})
      Configs.update(%{last_checked_at: now})
      broadcast(done)
      {:ok, done}
    else
      commit_and_push(run, config, roots, summary, now, git_opts)
    end
  end

  defp commit_and_push(run, config, roots, summary, now, git_opts) do
    sha =
      case Git.commit(commit_message(now), git_opts) do
        {:ok, s} ->
          s

        {:nochange} ->
          nil

        {:error, e} ->
          Logger.warning("dotfiles commit: #{e}")
          nil
      end

    {pushed, push_state} = push(config, git_opts)

    {:ok, done} =
      Runs.finalize(run, %{
        status: "success",
        finished_at: now,
        commit_sha: sha,
        pushed: pushed,
        files_changed: summary.changed,
        files_added: summary.added,
        files_deleted: summary.deleted
      })

    if sha, do: TrackedPaths.mark_first_backup(roots, now)

    Configs.update(Map.merge(%{last_checked_at: now, last_backup_at: now}, push_state))

    broadcast(done)
    {:ok, done}
  end

  # No remote configured: skip push entirely and leave push state untouched so
  # an intentionally-local setup never shows a spurious failure.
  defp push(%{remote_url: url}, _git_opts) when url in [nil, ""], do: {false, %{}}

  defp push(config, git_opts) do
    # Reconcile the wired remote to the config's URL before pushing so the DB
    # remains the single source of truth.
    _ = Git.ensure_remote(config.remote_name, config.remote_url, git_opts)

    case Git.push(config.remote_name, config.branch, git_opts) do
      :ok ->
        {true, %{last_push_ok: true, last_push_error: nil}}

      {:error, out} ->
        reason = Git.classify_remote_error(out)
        {false, %{last_push_ok: false, last_push_error: Atom.to_string(reason)}}
    end
  end

  defp finalize_error(run, err) do
    {:ok, done} =
      Runs.finalize(run, %{
        status: "error",
        finished_at: Clock.now(),
        error_message: to_string(err)
      })

    broadcast(done)
    {:ok, done}
  end

  defp collect_ignores(tracked) do
    tracked
    |> Enum.flat_map(fn t -> String.split(t.ignore_patterns || "", "\n", trim: true) end)
    |> Enum.uniq()
  end

  defp commit_message(now), do: "dotfiles backup #{DateTime.to_iso8601(now)}"
  defp manifest_path(opts), do: Keyword.get(opts, :work_tree) |> manifest_or_default(opts)
  defp manifest_or_default(nil, _), do: Paths.manifest_path()
  defp manifest_or_default(work, _), do: Path.join(work, Paths.manifest_relpath())
  defp manifest_relpath(_), do: Paths.manifest_relpath()

  defp broadcast(run) do
    broadcast_run({:run_finished, run.id, String.to_atom(run.status)})
    broadcast_status()
  end

  defp broadcast_run(msg), do: Phoenix.PubSub.broadcast(Fae.PubSub, Topics.dotfiles_runs(), msg)

  defp broadcast_status,
    do: Phoenix.PubSub.broadcast(Fae.PubSub, Topics.dotfiles_status(), {:dotfiles_changed})
end
