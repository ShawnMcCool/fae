defmodule Fae.Dotfiles.BackupPipelineTest do
  use Fae.DataCase, async: false
  alias Fae.Dotfiles.{BackupPipeline, Configs, Git, TrackedPaths}

  setup do
    base = Path.join(System.tmp_dir!(), "pipe-#{System.unique_integer([:positive])}")
    work = Path.join(base, "home")
    gd = Path.join(base, "repo.git")
    remote = Path.join(base, "remote.git")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ["init", "--bare", remote])
    opts = [git_dir: gd, work_tree: work]
    :ok = Git.init_bare(opts)
    :ok = Git.configure(opts)
    :ok = Git.set_remote("origin", remote, opts)
    {:ok, _} = Configs.update(%{initialized: true, remote_url: remote})
    on_exit(fn -> File.rm_rf!(base) end)
    %{opts: opts, work: work}
  end

  test "first run commits tracked dir + manifest, records success", %{opts: opts, work: work} do
    File.mkdir_p!(Path.join(work, ".config/app"))
    File.write!(Path.join(work, ".config/app/conf"), "v1")
    {:ok, _} = TrackedPaths.add(%{path: Path.join(work, ".config/app"), kind: "directory"})

    pkg = fn _, _, _ -> {"alpha\nbeta\n", 0} end
    {:ok, run} = BackupPipeline.run(opts: opts, package_cmd: pkg)

    assert run.status == "success"
    assert run.pushed
    assert {:ok, _sha} = Git.head_sha(opts)
    assert Configs.get().last_backup_at
  end

  test "second run with no changes records :no_changes, no commit", %{opts: opts, work: work} do
    File.mkdir_p!(Path.join(work, ".config/app"))
    File.write!(Path.join(work, ".config/app/conf"), "v1")
    {:ok, _} = TrackedPaths.add(%{path: Path.join(work, ".config/app"), kind: "directory"})
    pkg = fn _, _, _ -> {"alpha\n", 0} end
    {:ok, _} = BackupPipeline.run(opts: opts, package_cmd: pkg)
    {:ok, sha1} = Git.head_sha(opts)
    {:ok, run2} = BackupPipeline.run(opts: opts, package_cmd: pkg)
    assert run2.status == "no_changes"
    assert Git.head_sha(opts) == {:ok, sha1}
  end

  test "push failure still commits, records pushed: false with a classified error",
       %{opts: opts, work: work} do
    {:ok, _} = Configs.update(%{remote_url: "/nonexistent.git"})
    :ok = Git.set_remote("origin", "/nonexistent.git", opts)
    File.write!(Path.join(work, "f"), "x")
    {:ok, _} = TrackedPaths.add(%{path: Path.join(work, "f"), kind: "file"})
    pkg = fn _, _, _ -> {"a\n", 0} end
    {:ok, run} = BackupPipeline.run(opts: opts, package_cmd: pkg)
    assert run.status == "success"
    refute run.pushed
    config = Configs.get()
    refute config.last_push_ok
    # Classified short reason, not raw multiline git fatal text.
    assert config.last_push_error in ["not_found", "unreachable", "auth_failed"]
    refute config.last_push_error =~ "fatal"
    refute config.last_push_error =~ "\n"
  end

  test "remote_url nil: cycle commits, skips push, leaves push state neutral",
       %{opts: opts, work: work} do
    {:ok, _} = Configs.update(%{remote_url: nil, last_push_ok: true, last_push_error: nil})
    File.write!(Path.join(work, "f"), "x")
    {:ok, _} = TrackedPaths.add(%{path: Path.join(work, "f"), kind: "file"})
    pkg = fn _, _, _ -> {"a\n", 0} end
    {:ok, run} = BackupPipeline.run(opts: opts, package_cmd: pkg)

    assert run.status == "success"
    assert {:ok, _sha} = Git.head_sha(opts)
    refute run.pushed

    config = Configs.get()
    assert config.last_push_ok
    assert config.last_push_error == nil
  end

  test "remote_url set: cycle reconciles remote then pushes",
       %{opts: opts, work: work} do
    # Drift the wired remote; the pipeline should reconcile it to config.remote_url before push.
    :ok = Git.set_remote("origin", "/drifted.git", opts)
    File.write!(Path.join(work, "f"), "x")
    {:ok, _} = TrackedPaths.add(%{path: Path.join(work, "f"), kind: "file"})
    pkg = fn _, _, _ -> {"a\n", 0} end
    {:ok, run} = BackupPipeline.run(opts: opts, package_cmd: pkg)

    assert run.status == "success"
    assert run.pushed
    config = Configs.get()
    assert config.last_push_ok
    assert config.last_push_error == nil
  end
end
