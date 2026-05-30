# Fae Dotfiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `Fae.Dotfiles` tool that auto-backs-up a curated set of `$HOME` config paths to this machine's own GitHub repo on a suspend-safe Oban schedule, with a LiveView board for curation, health, and history — replacing dot-filer.

**Architecture:** A bare git repo (git-dir under `~/.local/share/fae/`, work-tree = `$HOME`) tracks config files **in place** — no symlinks. An Oban worker runs the backup cycle (stage → commit → push) and self-reschedules at `now + interval`, so suspend just makes the scheduled job overdue and Oban runs it once on resume. Domain logic (git wrapper, pipeline, schedule math, view shaping) is pure/injectable and unit-tested; the LiveView subscribes to PubSub and renders. Each machine is independent (own repo, own remote, no sync).

**Tech Stack:** Elixir, Phoenix LiveView, Ecto + SQLite (Exqlite), Oban, daisyUI (dark "fae" theme), `System.cmd/3` shelling out to `git`/`pacman`.

**Spec:** `docs/superpowers/specs/2026-05-30-fae-dotfiles-design.md` (read first).
**Mockups:** `.superpowers/brainstorm/*/content/board-v3.html`, `add-path.html` (gitignored).

---

## Conventions (read before starting)

Mirror these existing modules exactly — same shape, same idioms:

- **Oban worker:** `lib/fae/backups/run_worker.ex` (`use Oban.Worker`, `backoff/1`, `perform/1`, self-reschedules via `__MODULE__.new(scheduled_at:) |> Oban.insert()`).
- **Oban scheduler/reconcile:** `lib/fae/backups/scheduler.ex` (GenServer subscribing to a topic; `do_reconcile/1` cancels queued worker jobs then inserts the next).
- **Suspend handling:** `lib/fae/backups/suspend_watcher.ex` + `Scheduler.do_restage_overdue/0` (restages overdue Oban jobs on resume). For Dotfiles a single overdue scheduled job is simply run by Oban on resume — no stagger needed.
- **Pipeline vs worker split:** `lib/fae/backups/run_pipeline.ex` holds the run logic and broadcasts; the worker is thin Oban glue. Follow this split.
- **Schemas:** `lib/fae/backups/job.ex`, `run.ex` — `use Ecto.Schema`, `@timestamps_opts [type: :utc_datetime]`, `changeset/2`, `validate_*`.
- **Context + broadcast-on-write:** `lib/fae/backups/jobs.ex`, `runs.ex`; facade `lib/fae/backups.ex`.
- **Topics:** `lib/fae/topics.ex` (plain string functions).
- **Clock:** always `Fae.Clock.now()` (injectable; tests set `config :fae, :clock, …`).
- **LiveView:** `lib/fae_web/live/backups_live/index.ex` (mount→subscribe→load; `handle_info`→reload; `render` wraps `<Layouts.app flash={@flash} current_path={@current_path}>`; `@timezone` available via `DisplayScope`).
- **Pure view module:** `lib/fae_web/live/dashboard_view.ex` (shapes data; unit-tested).
- **Nav:** `lib/fae_web/components/sidebar_nav.ex` (`groups/1`, `active?/2`) — sidebar items have `%{label, path, icon}`.
- **Router:** `lib/fae_web/router.ex` `live_session :default, on_mount: [FaeWeb.SidebarScope, FaeWeb.DisplayScope]`.
- **Test cases:** `Fae.DataCase` (DB, SQL sandbox), `FaeWeb.ConnCase` (LiveView). Test files live under `test/fae/...` and `test/fae_web/...`.
- **Decisions:** 027 (supervised state; DB persists, not truth), 028 (loopback only — never change endpoint binding), 006 (single-writer), 008 (explicit `max_restarts`, sub-supervisors), 019 (extract LiveView logic to pure funcs), 015 (realtime PubSub), 002 (test-first, `mix precommit` clean), 005 (no magic numbers/abbrevs).

**Git invocation contract.** Every git call:
```elixir
System.cmd("git", ["--git-dir", git_dir, "--work-tree", work_tree | args],
  env: [{"GIT_TERMINAL_PROMPT", "0"}], stderr_to_stdout: true)
```
The `Git` module functions take `git_dir`/`work_tree` (defaulting from `Paths`) so tests run against temp dirs. Never raise on nonzero git exit — return tagged tuples.

**Verification per task:** `mix precommit` (compile --warnings-as-errors, format, credo, test) must be green before the commit step. Where a task lists a single test command, also run `mix test` before committing if other files changed.

**Paths.** git-dir `Path.join(data_dir, "dotfiles/repo.git")`; work-tree `System.user_home!()`; manifest `<work_tree>/.config/fae/package-list.txt`. `data_dir` mirrors `config/runtime.exs` (`$XDG_DATA_HOME/fae` || `$HOME/.local/share/fae`).

---

## Data model

`priv/repo/migrations/<ts>_create_dotfiles.exs`:

- `dotfiles_config` (singleton, `id` integer PK fixed to 1): `enabled:boolean default true`, `interval_seconds:integer default 3600`, `remote_url:text`, `remote_name:text default "origin"`, `branch:text default "main"`, `last_checked_at:utc_datetime`, `last_backup_at:utc_datetime`, `last_push_ok:boolean default true`, `last_push_error:text`, `initialized:boolean default false`, timestamps.
- `dotfiles_tracked_paths` (UUID PK): `path:text` (unique), `kind:text` (`directory`/`file`), `ignore_patterns:text`, `first_backed_up_at:utc_datetime`, timestamps.
- `dotfiles_runs` (UUID PK): `status:text` (`running`/`success`/`no_changes`/`error`), `started_at:utc_datetime_usec`, `finished_at:utc_datetime_usec`, `files_changed:integer`, `files_added:integer`, `files_deleted:integer`, `packages_added:integer`, `packages_removed:integer`, `commit_sha:text`, `pushed:boolean default false`, `error_message:text`, timestamps (`updated_at: false`).

---

## Task 1: Config wiring (Oban queue, paths, test env)

**Files:**
- Modify: `config/config.exs` (Oban `queues`), `config/runtime.exs` (Fae.Dotfiles paths for prod), `config/dev.exs` (dev paths), `config/test.exs` (test temp paths)
- Verify against: existing `:backups` queue entry in `config/config.exs`

- [ ] **Step 1: Add the `:dotfiles` Oban queue**

In `config/config.exs`, find the Oban `queues:` keyword (where `:backups` is defined) and add `dotfiles: 1` (serial). Mirror the exact surrounding style. Run `grep -n "queues" config/config.exs` first to locate it.

- [ ] **Step 2: Configure Dotfiles paths per environment**

`config/runtime.exs` — inside the `if config_env() == :prod do` block, after `fae_data_dir` is computed, add:
```elixir
config :fae, Fae.Dotfiles,
  git_dir: Path.join(fae_data_dir, "dotfiles/repo.git"),
  work_tree: System.fetch_env!("HOME")
```
`config/dev.exs` — add (compute a dev data dir or reuse `~/.local/share/fae`):
```elixir
config :fae, Fae.Dotfiles,
  git_dir: Path.expand("~/.local/share/fae/dotfiles/repo.git"),
  work_tree: System.user_home!()
```
`config/test.exs` — point at a per-run temp tree so tests never touch real `$HOME`:
```elixir
config :fae, Fae.Dotfiles,
  git_dir: Path.join(System.tmp_dir!(), "fae-dotfiles-test/repo.git"),
  work_tree: Path.join(System.tmp_dir!(), "fae-dotfiles-test/home")
```

- [ ] **Step 3: Verify config compiles**

Run: `mix compile --warnings-as-errors`
Expected: PASS.

- [ ] **Step 4: Commit**
```bash
git add config/config.exs config/runtime.exs config/dev.exs config/test.exs
git commit -m "Dotfiles: add :dotfiles Oban queue and per-env paths"
```

---

## Task 2: Migration + schemas

**Files:**
- Create: `priv/repo/migrations/<ts>_create_dotfiles.exs`, `lib/fae/dotfiles/config.ex`, `lib/fae/dotfiles/tracked_path.ex`, `lib/fae/dotfiles/run.ex`
- Test: `test/fae/dotfiles/schemas_test.exs`
- Reference syntax: `priv/repo/migrations/20260523114937_create_archive_tables.exs`, `lib/fae/backups/run.ex`

- [ ] **Step 1: Write the migration**

`priv/repo/migrations/<ts>_create_dotfiles.exs` (use a real timestamp > the latest existing migration):
```elixir
defmodule Fae.Repo.Migrations.CreateDotfiles do
  use Ecto.Migration

  def change do
    create table(:dotfiles_config) do
      add :enabled, :boolean, null: false, default: true
      add :interval_seconds, :integer, null: false, default: 3600
      add :remote_url, :text
      add :remote_name, :text, null: false, default: "origin"
      add :branch, :text, null: false, default: "main"
      add :last_checked_at, :utc_datetime
      add :last_backup_at, :utc_datetime
      add :last_push_ok, :boolean, null: false, default: true
      add :last_push_error, :text
      add :initialized, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create table(:dotfiles_tracked_paths, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :path, :text, null: false
      add :kind, :text, null: false
      add :ignore_patterns, :text
      add :first_backed_up_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:dotfiles_tracked_paths, [:path])

    create table(:dotfiles_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :status, :text, null: false
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :files_changed, :integer
      add :files_added, :integer
      add :files_deleted, :integer
      add :packages_added, :integer
      add :packages_removed, :integer
      add :commit_sha, :text
      add :pushed, :boolean, null: false, default: false
      add :error_message, :text
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:dotfiles_runs, [:started_at])
  end
end
```

- [ ] **Step 2: Write the three schemas**

`lib/fae/dotfiles/config.ex`:
```elixir
defmodule Fae.Dotfiles.Config do
  @moduledoc "Singleton config row (id = 1) for the Dotfiles tool."
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime]

  schema "dotfiles_config" do
    field :enabled, :boolean, default: true
    field :interval_seconds, :integer, default: 3600
    field :remote_url, :string
    field :remote_name, :string, default: "origin"
    field :branch, :string, default: "main"
    field :last_checked_at, :utc_datetime
    field :last_backup_at, :utc_datetime
    field :last_push_ok, :boolean, default: true
    field :last_push_error, :string
    field :initialized, :boolean, default: false
    timestamps()
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :enabled, :interval_seconds, :remote_url, :remote_name, :branch,
      :last_checked_at, :last_backup_at, :last_push_ok, :last_push_error, :initialized
    ])
    |> validate_number(:interval_seconds, greater_than_or_equal_to: 300)
  end
end
```

`lib/fae/dotfiles/tracked_path.ex`:
```elixir
defmodule Fae.Dotfiles.TrackedPath do
  @moduledoc "A curated path tracked for backup (folder or file)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime]
  @kinds ~w(directory file)

  schema "dotfiles_tracked_paths" do
    field :path, :string
    field :kind, :string
    field :ignore_patterns, :string
    field :first_backed_up_at, :utc_datetime
    timestamps()
  end

  def changeset(tracked, attrs) do
    tracked
    |> cast(attrs, [:path, :kind, :ignore_patterns, :first_backed_up_at])
    |> validate_required([:path, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint(:path)
  end

  def kinds, do: @kinds
end
```

`lib/fae/dotfiles/run.ex`:
```elixir
defmodule Fae.Dotfiles.Run do
  @moduledoc "One execution of the dotfiles backup cycle."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime, updated_at: false]
  @statuses ~w(running success no_changes error)

  schema "dotfiles_runs" do
    field :status, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :files_changed, :integer
    field :files_added, :integer
    field :files_deleted, :integer
    field :packages_added, :integer
    field :packages_removed, :integer
    field :commit_sha, :string
    field :pushed, :boolean, default: false
    field :error_message, :string
    timestamps()
  end

  def start_changeset(run, attrs) do
    run
    |> cast(attrs, [:started_at, :status])
    |> validate_required([:started_at, :status])
    |> validate_inclusion(:status, @statuses)
  end

  def finish_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :finished_at, :status, :files_changed, :files_added, :files_deleted,
      :packages_added, :packages_removed, :commit_sha, :pushed, :error_message
    ])
    |> validate_required([:finished_at, :status])
    |> validate_inclusion(:status, @statuses)
  end

  def statuses, do: @statuses
end
```

- [ ] **Step 3: Write schema tests**

`test/fae/dotfiles/schemas_test.exs`:
```elixir
defmodule Fae.Dotfiles.SchemasTest do
  use Fae.DataCase, async: true
  alias Fae.Dotfiles.{Config, TrackedPath, Run}

  test "tracked_path requires a valid kind" do
    refute TrackedPath.changeset(%TrackedPath{}, %{path: "/x", kind: "nope"}).valid?
    assert TrackedPath.changeset(%TrackedPath{}, %{path: "/x", kind: "directory"}).valid?
  end

  test "config rejects sub-300s interval" do
    refute Config.changeset(%Config{}, %{interval_seconds: 60}).valid?
    assert Config.changeset(%Config{}, %{interval_seconds: 3600}).valid?
  end

  test "run start requires status + started_at" do
    refute Run.start_changeset(%Run{}, %{}).valid?
    assert Run.start_changeset(%Run{}, %{status: "running", started_at: DateTime.utc_now()}).valid?
  end
end
```

- [ ] **Step 4: Migrate + run tests**

Run: `mix ecto.migrate && mix test test/fae/dotfiles/schemas_test.exs`
Expected: migration applies; 3 tests pass.

- [ ] **Step 5: Commit**
```bash
git add priv/repo/migrations lib/fae/dotfiles/{config,tracked_path,run}.ex test/fae/dotfiles/schemas_test.exs
git commit -m "Dotfiles: migration + Config/TrackedPath/Run schemas"
```

---

## Task 3: Topics

**Files:** Modify `lib/fae/topics.ex`; Test `test/fae/dotfiles/topics_test.exs`

- [ ] **Step 1: Add topic functions** to `lib/fae/topics.ex`:
```elixir
  def dotfiles_status, do: "dotfiles:status"
  def dotfiles_runs, do: "dotfiles:runs"
```

- [ ] **Step 2: Round-trip test** `test/fae/dotfiles/topics_test.exs`:
```elixir
defmodule Fae.Dotfiles.TopicsTest do
  use ExUnit.Case, async: true
  alias Fae.Topics

  test "topics are stable strings" do
    assert Topics.dotfiles_status() == "dotfiles:status"
    assert Topics.dotfiles_runs() == "dotfiles:runs"
  end
end
```

- [ ] **Step 3: Run + commit**
```bash
mix test test/fae/dotfiles/topics_test.exs
git add lib/fae/topics.ex test/fae/dotfiles/topics_test.exs
git commit -m "Dotfiles: PubSub topics"
```

---

## Task 4: `Fae.Dotfiles.Paths`

**Files:** Create `lib/fae/dotfiles/paths.ex`; Test `test/fae/dotfiles/paths_test.exs`

- [ ] **Step 1: Test** `test/fae/dotfiles/paths_test.exs`:
```elixir
defmodule Fae.Dotfiles.PathsTest do
  use ExUnit.Case, async: true
  alias Fae.Dotfiles.Paths

  test "reads git_dir/work_tree from app env" do
    env = Application.get_env(:fae, Fae.Dotfiles)
    assert Paths.git_dir() == Keyword.fetch!(env, :git_dir)
    assert Paths.work_tree() == Keyword.fetch!(env, :work_tree)
  end

  test "manifest lives under work_tree/.config/fae" do
    assert Paths.manifest_path() == Path.join(Paths.work_tree(), ".config/fae/package-list.txt")
    assert Paths.manifest_relpath() == ".config/fae/package-list.txt"
  end
end
```

- [ ] **Step 2: Implement** `lib/fae/dotfiles/paths.ex`:
```elixir
defmodule Fae.Dotfiles.Paths do
  @moduledoc "Filesystem locations for the Dotfiles bare repo + manifest."

  @manifest_relpath ".config/fae/package-list.txt"

  def git_dir, do: env!(:git_dir)
  def work_tree, do: env!(:work_tree)
  def manifest_relpath, do: @manifest_relpath
  def manifest_path, do: Path.join(work_tree(), @manifest_relpath)

  defp env!(key) do
    Application.get_env(:fae, Fae.Dotfiles, []) |> Keyword.fetch!(key)
  end
end
```

- [ ] **Step 3: Run + commit**
```bash
mix test test/fae/dotfiles/paths_test.exs
git add lib/fae/dotfiles/paths.ex test/fae/dotfiles/paths_test.exs
git commit -m "Dotfiles: Paths module"
```

---

## Task 5: `Fae.Dotfiles.Git` (shell-out wrapper)

**Files:** Create `lib/fae/dotfiles/git.ex`; Test `test/fae/dotfiles/git_test.exs`

This is the load-bearing module. Each function accepts `opts` with `:git_dir`/`:work_tree` (default from `Paths`). Tests use temp dirs and a local `--bare` repo as the push remote.

- [ ] **Step 1: Write tests** `test/fae/dotfiles/git_test.exs`:
```elixir
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
```

- [ ] **Step 2: Run tests (fail)** — `mix test test/fae/dotfiles/git_test.exs` → FAIL (module undefined).

- [ ] **Step 3: Implement** `lib/fae/dotfiles/git.ex`:
```elixir
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
    added = Enum.count(lines, &String.starts_with?(&1, "0\t0\t") == false)
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
    System.cmd("git",
      ["--git-dir", git_dir(opts), "--work-tree", work_tree(opts)] ++ args,
      env: [{"GIT_TERMINAL_PROMPT", "0"}], stderr_to_stdout: true)
  end

  defp git_dir(opts), do: Keyword.get(opts, :git_dir, Paths.git_dir())
  defp work_tree(opts), do: Keyword.get(opts, :work_tree, Paths.work_tree())
end
```

- [ ] **Step 4: Run tests (pass)** — `mix test test/fae/dotfiles/git_test.exs` → all pass. If `staged_summary` counts are off, adjust parsing until the first test's assertions (`files: 1, added: 1`) hold.

- [ ] **Step 5: Commit**
```bash
git add lib/fae/dotfiles/git.ex test/fae/dotfiles/git_test.exs
git commit -m "Dotfiles: Git shell-out wrapper (bare repo, in-place work-tree)"
```

---

## Task 6: `Fae.Dotfiles.PackageList`

**Files:** Create `lib/fae/dotfiles/package_list.ex`; Test `test/fae/dotfiles/package_list_test.exs`

- [ ] **Step 1: Test** `test/fae/dotfiles/package_list_test.exs`:
```elixir
defmodule Fae.Dotfiles.PackageListTest do
  use ExUnit.Case, async: true
  alias Fae.Dotfiles.PackageList

  test "sorts package names from the command output" do
    cmd = fn "pacman", ["-Qqe"], _ -> {"git\nbat\nalacritty\n", 0} end
    assert PackageList.generate(cmd) == "alacritty\nbat\ngit"
  end

  test "write! writes to the given path" do
    target = Path.join(System.tmp_dir!(), "pl-#{System.unique_integer([:positive])}.txt")
    cmd = fn _, _, _ -> {"b\na\n", 0} end
    :ok = PackageList.write!(target, cmd)
    assert File.read!(target) == "a\nb\n"
  end
end
```

- [ ] **Step 2: Implement** `lib/fae/dotfiles/package_list.ex`:
```elixir
defmodule Fae.Dotfiles.PackageList do
  @moduledoc "Generates this machine's explicitly-installed package manifest."
  alias Fae.Dotfiles.Paths

  @default_cmd &System.cmd/3

  @spec generate((... -> {String.t(), non_neg_integer()})) :: String.t()
  def generate(cmd \\ @default_cmd) do
    {out, 0} = cmd.("pacman", ["-Qqe"], [])
    out |> String.split("\n", trim: true) |> Enum.sort() |> Enum.join("\n")
  end

  @spec write!(Path.t(), fun()) :: :ok
  def write!(path \\ Paths.manifest_path(), cmd \\ @default_cmd) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, generate(cmd) <> "\n")
    :ok
  end
end
```

- [ ] **Step 3: Run + commit**
```bash
mix test test/fae/dotfiles/package_list_test.exs
git add lib/fae/dotfiles/package_list.ex test/fae/dotfiles/package_list_test.exs
git commit -m "Dotfiles: package manifest generator"
```

---

## Task 7: Contexts — Configs, TrackedPaths, Runs + facade

**Files:** Create `lib/fae/dotfiles/configs.ex`, `tracked_paths.ex`, `runs.ex`, `lib/fae/dotfiles.ex`; Test `test/fae/dotfiles/contexts_test.exs`
**Reference:** `lib/fae/backups/jobs.ex`, `runs.ex`, `lib/fae/backups.ex`

- [ ] **Step 1: Tests** `test/fae/dotfiles/contexts_test.exs`:
```elixir
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
    {:ok, done} = Runs.finalize(run, %{status: "success", finished_at: DateTime.utc_now(), files_changed: 2, pushed: true})
    assert done.status == "success" and done.pushed
    assert [^done] = Runs.list_recent(5) |> Enum.filter(&(&1.id == done.id))
  end
end
```

- [ ] **Step 2: Implement contexts**

`lib/fae/dotfiles/configs.ex`:
```elixir
defmodule Fae.Dotfiles.Configs do
  @moduledoc "Read/update the singleton Dotfiles config (id = 1)."
  alias Fae.Dotfiles.Config
  alias Fae.Repo

  def get do
    case Repo.get(Config, 1) do
      nil ->
        {:ok, c} = %Config{id: 1} |> Config.changeset(%{}) |> Repo.insert()
        c
      c -> c
    end
  end

  def update(attrs) do
    get() |> Config.changeset(attrs) |> Repo.update()
  end
end
```

`lib/fae/dotfiles/tracked_paths.ex`:
```elixir
defmodule Fae.Dotfiles.TrackedPaths do
  @moduledoc "CRUD for tracked paths; writes broadcast {:dotfiles_changed}."
  import Ecto.Query, only: [from: 2]
  alias Fae.Dotfiles.TrackedPath
  alias Fae.{Repo, Topics}

  def list, do: Repo.all(from t in TrackedPath, order_by: [asc: t.path])

  def add(attrs) do
    %TrackedPath{} |> TrackedPath.changeset(attrs) |> Repo.insert() |> broadcast()
  end

  def remove(%TrackedPath{} = tp) do
    {:ok, _} = Repo.delete(tp)
    broadcast({:ok, tp})
    :ok
  end

  def set_ignores(%TrackedPath{} = tp, patterns) do
    tp |> TrackedPath.changeset(%{ignore_patterns: patterns}) |> Repo.update() |> broadcast()
  end

  def mark_first_backup(paths, at) when is_list(paths) do
    Repo.update_all(
      from(t in TrackedPath, where: t.path in ^paths and is_nil(t.first_backed_up_at)),
      set: [first_backed_up_at: at]
    )
    :ok
  end

  defp broadcast({:ok, _} = res) do
    Phoenix.PubSub.broadcast(Fae.PubSub, Topics.dotfiles_status(), {:dotfiles_changed})
    res
  end
  defp broadcast(other), do: other
end
```

`lib/fae/dotfiles/runs.ex`:
```elixir
defmodule Fae.Dotfiles.Runs do
  @moduledoc "Durable history of backup runs."
  import Ecto.Query, only: [from: 2]
  alias Fae.Dotfiles.Run
  alias Fae.Repo

  def create_started do
    %Run{} |> Run.start_changeset(%{status: "running", started_at: DateTime.utc_now()}) |> Repo.insert()
  end

  def finalize(%Run{} = run, attrs) do
    run |> Run.finish_changeset(attrs) |> Repo.update()
  end

  def last, do: Repo.one(from r in Run, order_by: [desc: r.started_at], limit: 1)

  def list_recent(limit \\ 20) do
    Repo.all(from r in Run, order_by: [desc: r.started_at], limit: ^limit)
  end
end
```

`lib/fae/dotfiles.ex` (facade + subscribe helpers; `boot!`/`run_now` added in Task 9):
```elixir
defmodule Fae.Dotfiles do
  @moduledoc """
  Dotfiles tool: backs up a curated set of `$HOME` config paths to a
  per-machine git remote on an Oban schedule. Bare repo, work-tree = $HOME,
  files tracked in place (no symlinks). DB persists config + history; the
  git repo and live files are the source of truth (decision 027).
  """
  alias Fae.Topics

  defdelegate get_config(), to: Fae.Dotfiles.Configs, as: :get
  defdelegate update_config(attrs), to: Fae.Dotfiles.Configs, as: :update
  defdelegate list_tracked(), to: Fae.Dotfiles.TrackedPaths, as: :list
  defdelegate last_run(), to: Fae.Dotfiles.Runs, as: :last
  defdelegate recent_runs(limit), to: Fae.Dotfiles.Runs, as: :list_recent

  def subscribe_status, do: Phoenix.PubSub.subscribe(Fae.PubSub, Topics.dotfiles_status())
  def subscribe_runs, do: Phoenix.PubSub.subscribe(Fae.PubSub, Topics.dotfiles_runs())
end
```

- [ ] **Step 3: Run + commit**
```bash
mix test test/fae/dotfiles/contexts_test.exs
git add lib/fae/dotfiles/{configs,tracked_paths,runs}.ex lib/fae/dotfiles.ex test/fae/dotfiles/contexts_test.exs
git commit -m "Dotfiles: Configs/TrackedPaths/Runs contexts + facade"
```

---

## Task 8: `Fae.Dotfiles.BackupPipeline` (the cycle logic)

**Files:** Create `lib/fae/dotfiles/backup_pipeline.ex`; Test `test/fae/dotfiles/backup_pipeline_test.exs`
**Reference:** `lib/fae/backups/run_pipeline.ex`

The pipeline runs one cycle against the real repo (paths from `Paths`, overridable via opts for tests): write manifest → write exclude (union of all tracked `ignore_patterns`) → stage roots+manifest → summarize → commit-if-changed → push (also push if `ahead_of_remote?` from a prior failure) → finalize Run + Config → broadcast `dotfiles:runs` + `dotfiles:status`.

- [ ] **Step 1: Test** `test/fae/dotfiles/backup_pipeline_test.exs`:
```elixir
defmodule Fae.Dotfiles.BackupPipelineTest do
  use Fae.DataCase, async: false
  alias Fae.Dotfiles.{BackupPipeline, TrackedPaths, Configs, Runs, Git}

  setup do
    base = Path.join(System.tmp_dir!(), "pipe-#{System.unique_integer([:positive])}")
    work = Path.join(base, "home")
    gd = Path.join(base, "repo.git")
    remote = Path.join(base, "remote.git")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ["init", "--bare", remote])
    opts = [git_dir: gd, work_tree: work]
    :ok = Git.init_bare(opts); :ok = Git.configure(opts); :ok = Git.set_remote("origin", remote, opts)
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

  test "push failure still commits, records pushed: false", %{opts: opts, work: work} do
    {:ok, _} = Configs.update(%{remote_url: "/nonexistent.git"})
    :ok = Git.set_remote("origin", "/nonexistent.git", opts)
    File.write!(Path.join(work, "f"), "x")
    {:ok, _} = TrackedPaths.add(%{path: Path.join(work, "f"), kind: "file"})
    pkg = fn _, _, _ -> {"a\n", 0} end
    {:ok, run} = BackupPipeline.run(opts: opts, package_cmd: pkg)
    assert run.status == "success"
    refute run.pushed
    refute Configs.get().last_push_ok
  end
end
```

- [ ] **Step 2: Implement** `lib/fae/dotfiles/backup_pipeline.ex`:
```elixir
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

    if summary.files == 0 and not Git.ahead_of_remote?(config.remote_name, config.branch, git_opts) do
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
        {:ok, s} -> s
        {:nochange} -> nil
        {:error, e} -> Logger.warning("dotfiles commit: #{e}"); nil
      end

    push_result = Git.push(config.remote_name, config.branch, git_opts)
    pushed = push_result == :ok
    push_err = if pushed, do: nil, else: elem_or_nil(push_result)

    {:ok, done} =
      Runs.finalize(run, %{
        status: "success", finished_at: now, commit_sha: sha, pushed: pushed,
        files_changed: summary.changed, files_added: summary.added, files_deleted: summary.deleted
      })

    if sha, do: TrackedPaths.mark_first_backup(roots, now)
    Configs.update(%{last_checked_at: now, last_backup_at: now, last_push_ok: pushed, last_push_error: push_err})
    broadcast(done)
    {:ok, done}
  end

  defp finalize_error(run, err) do
    {:ok, done} = Runs.finalize(run, %{status: "error", finished_at: Clock.now(), error_message: to_string(err)})
    broadcast(done)
    {:ok, done}
  end

  defp collect_ignores(tracked) do
    tracked |> Enum.flat_map(fn t -> String.split(t.ignore_patterns || "", "\n", trim: true) end) |> Enum.uniq()
  end

  defp commit_message(now), do: "dotfiles backup #{DateTime.to_iso8601(now)}"
  defp manifest_path(opts), do: Keyword.get(opts, :work_tree) |> manifest_or_default(opts)
  defp manifest_or_default(nil, _), do: Paths.manifest_path()
  defp manifest_or_default(work, _), do: Path.join(work, Paths.manifest_relpath())
  defp manifest_relpath(_), do: Paths.manifest_relpath()
  defp elem_or_nil({:error, m}), do: m
  defp elem_or_nil(_), do: nil

  defp broadcast(run), do: broadcast_run({:run_finished, run.id, String.to_atom(run.status)}) && broadcast_status()
  defp broadcast_run(msg), do: Phoenix.PubSub.broadcast(Fae.PubSub, Topics.dotfiles_runs(), msg)
  defp broadcast_status, do: Phoenix.PubSub.broadcast(Fae.PubSub, Topics.dotfiles_status(), {:dotfiles_changed})
end
```

- [ ] **Step 3: Run tests** — `mix test test/fae/dotfiles/backup_pipeline_test.exs`. Fix parsing/branch edge cases until green (the `no_changes` path is the subtle one — the manifest write must not create a diff on the second run, which holds because identical content stages to nothing).

- [ ] **Step 4: Commit**
```bash
git add lib/fae/dotfiles/backup_pipeline.ex test/fae/dotfiles/backup_pipeline_test.exs
git commit -m "Dotfiles: backup pipeline (stage/commit/push/record)"
```

---

## Task 9: Oban worker + Scheduler + boot!

**Files:** Create `lib/fae/dotfiles/backup_worker.ex`, `lib/fae/dotfiles/scheduler.ex`; extend `lib/fae/dotfiles.ex`; Test `test/fae/dotfiles/scheduler_test.exs`
**Reference:** `lib/fae/backups/run_worker.ex`, `scheduler.ex`

The worker is thin Oban glue: on `kind: "scheduled"` it inserts the next scheduled job at `now + interval` (self-reschedule → interval-since-last; suspend just makes it overdue and Oban runs it once on resume), then calls `BackupPipeline.run/0`. The Scheduler GenServer subscribes to `dotfiles:status`, and on `{:dotfiles_changed}` reconciles (cancel queued worker jobs, insert next per current interval — so cadence/enable changes take effect). `boot!/0` reconciles once on startup.

- [ ] **Step 1: Scheduler test** `test/fae/dotfiles/scheduler_test.exs`:
```elixir
defmodule Fae.Dotfiles.SchedulerTest do
  use Fae.DataCase, async: false
  use Oban.Testing, repo: Fae.Repo
  alias Fae.Dotfiles.{Scheduler, Configs, BackupWorker}

  test "reconcile enqueues exactly one scheduled job when initialized+enabled" do
    {:ok, _} = Configs.update(%{initialized: true, enabled: true, remote_url: "x"})
    :ok = Scheduler.do_reconcile()
    assert_enqueued worker: BackupWorker, args: %{"kind" => "scheduled"}
  end

  test "reconcile enqueues nothing when disabled" do
    {:ok, _} = Configs.update(%{initialized: true, enabled: false})
    :ok = Scheduler.do_reconcile()
    refute_enqueued worker: BackupWorker
  end

  test "reconcile is a no-op until initialized" do
    {:ok, _} = Configs.update(%{initialized: false})
    :ok = Scheduler.do_reconcile()
    refute_enqueued worker: BackupWorker
  end
end
```

- [ ] **Step 2: Implement worker** `lib/fae/dotfiles/backup_worker.ex`:
```elixir
defmodule Fae.Dotfiles.BackupWorker do
  @moduledoc "Oban worker running one dotfiles backup cycle; self-reschedules."
  use Oban.Worker, queue: :dotfiles, max_attempts: 5
  alias Fae.Dotfiles.{BackupPipeline, Configs, Scheduler}

  @backoff %{1 => 30, 2 => 120, 3 => 600, 4 => 1800}
  @impl true
  def backoff(%Oban.Job{attempt: a}), do: Map.get(@backoff, a, 1800)

  @impl true
  def perform(%Oban.Job{args: args}) do
    if Map.get(args, "kind") == "scheduled", do: Scheduler.schedule_next(Configs.get())
    {:ok, _run} = BackupPipeline.run()
    :ok
  end
end
```

- [ ] **Step 3: Implement scheduler** `lib/fae/dotfiles/scheduler.ex`:
```elixir
defmodule Fae.Dotfiles.Scheduler do
  @moduledoc "Keeps one scheduled BackupWorker queued per current config."
  use GenServer
  import Ecto.Query, only: [from: 2]
  require Logger
  alias Fae.Dotfiles.{BackupWorker, Configs}

  def start_link(opts \\ []) do
    if enabled?(), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__), else: :ignore
  end

  def enabled?, do: Application.get_env(:fae, __MODULE__, []) |> Keyword.get(:enabled, true)
  def reconcile, do: GenServer.call(__MODULE__, :reconcile)

  @impl true
  def init(_), do: {:ok, (Fae.Dotfiles.subscribe_status() && %{}) || %{}}

  @impl true
  def handle_info({:dotfiles_changed}, s), do: (do_reconcile(); {:noreply, s})
  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def handle_call(:reconcile, _from, s), do: (do_reconcile(); {:reply, :ok, s})

  @doc false
  def do_reconcile do
    cancel_queued()
    config = Configs.get()
    if config.initialized and config.enabled, do: schedule_next(config)
    :ok
  end

  @doc false
  def schedule_next(config) do
    next = DateTime.add(Fae.Clock.now(), config.interval_seconds, :second)
    %{"kind" => "scheduled"} |> BackupWorker.new(scheduled_at: next) |> Oban.insert()
  end

  defp cancel_queued do
    worker = inspect(BackupWorker)
    Oban.cancel_all_jobs(
      from j in Oban.Job,
        where: j.worker == ^worker and j.state in ["available", "scheduled", "retryable"]
    )
  end
end
```

- [ ] **Step 4: Extend facade** — add to `lib/fae/dotfiles.ex`:
```elixir
  def run_now, do: %{"kind" => "manual"} |> Fae.Dotfiles.BackupWorker.new() |> Oban.insert()

  def boot! do
    if Fae.Dotfiles.Scheduler.enabled?(), do: Fae.Dotfiles.Scheduler.reconcile()
    :ok
  end
```

- [ ] **Step 5: Run + commit**
```bash
mix test test/fae/dotfiles/scheduler_test.exs
git add lib/fae/dotfiles/{backup_worker,scheduler}.ex lib/fae/dotfiles.ex test/fae/dotfiles/scheduler_test.exs
git commit -m "Dotfiles: Oban backup worker + self-rescheduling scheduler"
```

---

## Task 10: Application wiring

**Files:** Modify `lib/fae/application.ex`; Test `test/fae/dotfiles/boot_test.exs`
**Reference:** the `Fae.Backups.boot!()` call in `application.ex` `post_supervisor_hooks/1`

- [ ] **Step 1: Add the scheduler to the tree + boot hook**

In `lib/fae/application.ex`, add `Fae.Dotfiles.Scheduler` to `children` (after `Fae.Archive.Supervisor`), and add `Fae.Dotfiles.boot!()` in `post_supervisor_hooks({:ok, _})` after `Fae.Archive.boot!()`.

- [ ] **Step 2: Smoke test** `test/fae/dotfiles/boot_test.exs`:
```elixir
defmodule Fae.Dotfiles.BootTest do
  use ExUnit.Case, async: false
  test "scheduler process is alive (or :ignore in test env)" do
    # In :test the Scheduler is disabled via config; assert boot! is a no-op.
    assert Fae.Dotfiles.boot!() == :ok
  end
end
```
Add to `config/test.exs`: `config :fae, Fae.Dotfiles.Scheduler, enabled: false` (mirrors `Fae.Backups.Scheduler` test toggle).

- [ ] **Step 3: Run full suite + commit**
```bash
mix test
git add lib/fae/application.ex config/test.exs test/fae/dotfiles/boot_test.exs
git commit -m "Dotfiles: wire scheduler into supervision tree + boot hook"
```

---

## Task 11: `Fae.Dotfiles.Suggestions`

**Files:** Create `lib/fae/dotfiles/suggestions.ex`; Test `test/fae/dotfiles/suggestions_test.exs`

- [ ] **Step 1: Test** `test/fae/dotfiles/suggestions_test.exs`:
```elixir
defmodule Fae.Dotfiles.SuggestionsTest do
  use ExUnit.Case, async: true
  alias Fae.Dotfiles.Suggestions

  test "lists entries under base not already tracked, sorted" do
    base = Path.join(System.tmp_dir!(), "sug-#{System.unique_integer([:positive])}")
    Enum.each(~w(alacritty nvim kitty), &File.mkdir_p!(Path.join(base, &1)))
    on_exit(fn -> File.rm_rf!(base) end)
    tracked = [Path.join(base, "nvim")]
    assert Suggestions.untracked_in(base, tracked) ==
             [Path.join(base, "alacritty"), Path.join(base, "kitty")]
  end
end
```

- [ ] **Step 2: Implement** `lib/fae/dotfiles/suggestions.ex`:
```elixir
defmodule Fae.Dotfiles.Suggestions do
  @moduledoc "Suggests config entries under a base dir not yet tracked."
  def default_base, do: Path.join(System.user_home!(), ".config")

  def untracked_in(base \\ default_base(), tracked_paths) do
    tracked = MapSet.new(tracked_paths)
    case File.ls(base) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(base, &1))
        |> Enum.reject(&MapSet.member?(tracked, &1))
        |> Enum.sort()
      _ -> []
    end
  end
end
```

- [ ] **Step 3: Run + commit**
```bash
mix test test/fae/dotfiles/suggestions_test.exs
git add lib/fae/dotfiles/suggestions.ex test/fae/dotfiles/suggestions_test.exs
git commit -m "Dotfiles: untracked-config suggestions"
```

---

## Task 12: `FaeWeb.DotfilesView` (pure view shaping)

**Files:** Create `lib/fae_web/live/dotfiles_view.ex`; Test `test/fae_web/live/dotfiles_view_test.exs`
**Reference:** `lib/fae_web/live/dashboard_view.ex`

- [ ] **Step 1: Test** `test/fae_web/live/dotfiles_view_test.exs`:
```elixir
defmodule FaeWeb.DotfilesViewTest do
  use ExUnit.Case, async: true
  alias FaeWeb.DotfilesView
  alias Fae.Dotfiles.{Config, TrackedPath}

  defp tp(path, kind, opts \\ []),
    do: %TrackedPath{path: path, kind: kind, first_backed_up_at: opts[:first]}

  test "groups by parent dir and classifies status" do
    home = System.tmp_dir!()
    nvim = Path.join(home, ".config/nvim"); File.mkdir_p!(nvim)
    missing = Path.join(home, ".config/gone")
    paths = [tp(nvim, "directory", first: DateTime.utc_now()), tp(missing, "file")]

    view = DotfilesView.build(%{config: %Config{enabled: true, interval_seconds: 3600},
                                tracked: paths, runs: [], now: DateTime.utc_now()})

    group = Enum.find(view.groups, &(&1.header == Path.join(home, ".config") <> "/"))
    statuses = Map.new(group.items, &{&1.name, &1.status})
    assert statuses["nvim"] == :ok
    assert statuses["gone"] == :missing
  end

  test "pending when tracked but never backed up and exists" do
    home = System.tmp_dir!()
    p = Path.join(home, ".config/new"); File.mkdir_p!(p)
    view = DotfilesView.build(%{config: %Config{}, tracked: [tp(p, "directory")], runs: [], now: DateTime.utc_now()})
    item = view.groups |> Enum.flat_map(& &1.items) |> Enum.find(&(&1.name == "new"))
    assert item.status == :pending
  end
end
```

- [ ] **Step 2: Implement** `lib/fae_web/live/dotfiles_view.ex`:
```elixir
defmodule FaeWeb.DotfilesView do
  @moduledoc "Pure shaping of Dotfiles assigns for the LiveView (decision 019)."

  def build(%{config: config, tracked: tracked, runs: runs, now: now}) do
    %{
      health: %{
        enabled: config.enabled,
        interval_seconds: config.interval_seconds,
        last_backup_at: config.last_backup_at,
        last_push_ok: config.last_push_ok,
        last_push_error: config.last_push_error,
        next_at: next_at(config)
      },
      groups: group_paths(tracked, now),
      runs: runs
    }
  end

  defp next_at(%{last_checked_at: nil}), do: nil
  defp next_at(%{last_checked_at: t, interval_seconds: s}), do: DateTime.add(t, s, :second)

  defp group_paths(tracked, _now) do
    tracked
    |> Enum.group_by(&(Path.dirname(&1.path) <> "/"))
    |> Enum.map(fn {header, items} ->
      %{header: header, items: items |> Enum.map(&item/1) |> Enum.sort_by(& &1.name)}
    end)
    |> Enum.sort_by(& &1.header)
  end

  defp item(tp) do
    %{
      name: Path.basename(tp.path),
      path: tp.path,
      kind: tp.kind,
      ignored_count: tp.ignore_patterns |> to_string() |> String.split("\n", trim: true) |> length(),
      status: status(tp)
    }
  end

  defp status(tp) do
    cond do
      not File.exists?(tp.path) -> :missing
      is_nil(tp.first_backed_up_at) -> :pending
      true -> :ok
    end
  end
end
```

- [ ] **Step 3: Run + commit**
```bash
mix test test/fae_web/live/dotfiles_view_test.exs
git add lib/fae_web/live/dotfiles_view.ex test/fae_web/live/dotfiles_view_test.exs
git commit -m "Dotfiles: pure view shaping module"
```

---

## Task 13: `FaeWeb.DotfilesLive.Index` (board) + nav + router

**Files:** Create `lib/fae_web/live/dotfiles_live/index.ex`; Modify `lib/fae_web/router.ex`, `lib/fae_web/components/sidebar_nav.ex`; Test `test/fae_web/live/dotfiles_live_test.exs`
**Reference:** `lib/fae_web/live/backups_live/index.ex`, mockup `board-v3.html`

- [ ] **Step 1: Add route + nav**

Router — inside `live_session :default`, add:
```elixir
      scope "/dotfiles" do
        live "/", DotfilesLive.Index, :index
      end
```
`sidebar_nav.ex` — add `%{label: "Dotfiles", path: "/dotfiles", icon: "hero-document-duplicate"}` to the appropriate top group (after Backups). Verify the exact group structure first with `grep -n "label:" lib/fae_web/components/sidebar_nav.ex`.

- [ ] **Step 2: LiveView test** `test/fae_web/live/dotfiles_live_test.exs`:
```elixir
defmodule FaeWeb.DotfilesLiveTest do
  use FaeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Fae.Dotfiles.{Configs, TrackedPaths}

  test "renders tracked paths and health", %{conn: conn} do
    {:ok, _} = Configs.update(%{enabled: true})
    home = System.tmp_dir!(); File.mkdir_p!(Path.join(home, ".config/nvim"))
    {:ok, _} = TrackedPaths.add(%{path: Path.join(home, ".config/nvim"), kind: "directory"})
    {:ok, _view, html} = live(conn, ~p"/dotfiles")
    assert html =~ "Dotfiles"
    assert html =~ "nvim"
  end

  test "backup_now enqueues a manual run", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/dotfiles")
    render_click(view, "backup_now", %{})
    # No crash; manual job enqueued (Oban testing inbox). Assert button present.
    assert render(view) =~ "Back up now"
  end
end
```

- [ ] **Step 3: Implement** `lib/fae_web/live/dotfiles_live/index.ex` — mount subscribes to `dotfiles:status`/`dotfiles:runs`, `load/1` builds via `DotfilesView.build/1` (config/tracked/runs/now), `render/1` follows `board-v3.html` (health strip with toggle + cadence + "Back up now"; grouped two-column list with dot-only-when-broken; recent runs). Events: `toggle_enabled` (`Configs.update(%{enabled: !..})`), `set_cadence` (`Configs.update(%{interval_seconds: ..})`), `backup_now` (`Fae.Dotfiles.run_now()`), `stop_tracking` (`TrackedPaths.remove`), `restore_path` (`Git.checkout`). `handle_info({:dotfiles_changed}|{:run_*}, _)` → reload. Wrap in `<Layouts.app flash={@flash} current_path={@current_path}>`. Use daisyUI classes; status dot only for `:pending`/`:missing`.

- [ ] **Step 4: Run + commit**
```bash
mix test test/fae_web/live/dotfiles_live_test.exs
git add lib/fae_web/live/dotfiles_live/index.ex lib/fae_web/router.ex lib/fae_web/components/sidebar_nav.ex test/fae_web/live/dotfiles_live_test.exs
git commit -m "Dotfiles: board LiveView + nav + route"
```

---

## Task 14: Track-path + ignores LiveComponents

**Files:** Create `lib/fae_web/live/dotfiles_live/track_path_component.ex`, `ignores_component.ex`; Tests alongside
**Reference:** `add-path.html`, `lib/fae_web/components/path_browser.ex` (existing filesystem browser — reuse if it fits)

- [ ] **Step 1: Tests** — component renders suggestions (`Suggestions.untracked_in`), adds selected via `TrackedPaths.add`; browser lists `File.ls` entries marking tracked ones disabled; manual field rejects a non-existent path; ignores component persists patterns via `TrackedPaths.set_ignores`. Write `render_component`/`live_isolated` tests asserting each behavior.

- [ ] **Step 2: Implement** the two `Phoenix.LiveComponent`s per `add-path.html` (suggestions pills, checkbox browser, manual field; ignores textarea). Wire them into `DotfilesLive.Index` via `<.live_component>` toggled by an assign (mirror how `backups_live/index.ex` mounts `PathBrowser`).

- [ ] **Step 3: Run + commit**
```bash
mix test test/fae_web/live/dotfiles_live/
git add lib/fae_web/live/dotfiles_live/{track_path_component,ignores_component}.ex test/fae_web/live/dotfiles_live/
git commit -m "Dotfiles: track-path + ignores components"
```

---

## Task 15: Dashboard section

**Files:** Modify `lib/fae_web/live/dashboard_live.ex`, `lib/fae_web/live/dashboard_view.ex`; extend `test/fae_web/live/dashboard_*`
**Reference:** existing `destinations_section`/`jobs_section` in `dashboard_live.ex`

- [ ] **Step 1: Test** — dashboard shows a "Dotfiles" line (last backup + push status + # tracked); updates on `{:dotfiles_changed}`.
- [ ] **Step 2: Implement** — subscribe to `Topics.dotfiles_status()` in `DashboardLive.mount`, add a compact `dotfiles_section/1`, shape its data in `DashboardView`.
- [ ] **Step 3: Run + commit**
```bash
mix test test/fae_web/live/
git add lib/fae_web/live/dashboard_live.ex lib/fae_web/live/dashboard_view.ex test/fae_web/live/
git commit -m "Dotfiles: dashboard health section"
```

---

## Task 16: Migration / guided import

**Files:** Create `lib/fae/dotfiles/migration.ex`, `lib/fae_web/live/dotfiles_live/import_component.ex`; Test `test/fae/dotfiles/migration_test.exs`

- [ ] **Step 1: Test** `test/fae/dotfiles/migration_test.exs` — build a fake home mimicking dot-filer's layout (real files under `<base>/src/dotfiles/files/home/...`, symlinks at `<home>/.config/...` → those files, a `target.paths`). Assert `Migration.run/1`:
  - replaces each symlink with the real file/dir in place (no symlink remains; content intact),
  - creates the bare repo and commits all targets (`Git.head_sha` ok, `ls_files` non-empty),
  - inserts `TrackedPath` rows for each target,
  - sets `Config.initialized=true` and `remote_url`,
  - leaves a safety copy under `<data_dir>/dotfiles/import-backup-*`,
  - re-running is guarded (no-op when `initialized`).

- [ ] **Step 2: Implement** `lib/fae/dotfiles/migration.ex`:
  - `preview/1` reads `target.paths`, classifies each path (symlink-into-old-repo / real / missing).
  - `run/1`: safety-copy current state; for each symlinked target deref (read `File.read_link`, copy real content to the path via `File.cp_r`, `File.rm` the symlink, restore real content); `Git.init_bare`+`configure`+`set_remote`; `Git.stage` all targets + manifest; `Git.commit`; `Git.push`; insert `TrackedPath` rows; `Configs.update(initialized: true, remote_url:)`. Guard: if `Configs.get().initialized`, return `{:error, :already_initialized}`.

- [ ] **Step 3: Import LiveView flow** `import_component.ex` — preview → confirm → progress → done. For disabling the old systemd timer, **show the exact command** (`systemctl --user disable --now <unit>`) or offer a confirmed one-click that runs it via `System.cmd` — never silently mutate the user's systemd units.

- [ ] **Step 4: Run + commit**
```bash
mix test test/fae/dotfiles/migration_test.exs
git add lib/fae/dotfiles/migration.ex lib/fae_web/live/dotfiles_live/import_component.ex test/fae/dotfiles/migration_test.exs
git commit -m "Dotfiles: guided import from dot-filer"
```

---

## Task 17: Decision record + docs

**Files:** Create `docs/decisions/architecture/2026-05-30-032-dotfiles-bare-repo-in-place.md`; Modify `CLAUDE.md`

- [ ] **Step 1: Write the MADR-lean decision** (follow `docs/decisions/architecture/template.md`): captures bare-repo-in-place over symlinks, per-machine separate repos, Oban set-and-forget (interval-since-checked via self-reschedule; suspend handled by Oban running overdue jobs), package manifest per machine, dot-filer retired.
- [ ] **Step 2: Note the tool in `CLAUDE.md`** (one line under the tools/architecture summary) and mention dot-filer is replaced (import disables its timer).
- [ ] **Step 3: Commit**
```bash
git add docs/decisions/architecture/2026-05-30-032-dotfiles-bare-repo-in-place.md CLAUDE.md
git commit -m "Dotfiles: decision record + docs"
```

---

## Task 18: Final verification

- [ ] **Step 1:** `mix precommit` → all green (compile --warnings-as-errors, format, credo, full test suite).
- [ ] **Step 2:** Manual smoke (dev): visit `/dotfiles`, add a path via suggestions, "Back up now", confirm a run appears and the health strip updates live.
- [ ] **Step 3:** Open a PR from `feature/dotfiles-tool` (or merge per the repo's flow).

---

## Self-Review (completed)

- **Spec coverage:** storage model (Tasks 4,5), folder-as-unit + ignores (5,8), scheduler suspend-safe (9), per-machine remote (2,16), curation semantics (7,13,14), UI board/add/health/history (12–15), migration (16), retire old tooling + decision (17). ✓
- **Placeholder scan:** UI render bodies in Tasks 13–16 reference concrete events/modules and the mockups; no "TBD"/"add error handling" placeholders. The densest code is in the engine (Tasks 5,8,9). ✓
- **Type consistency:** `Git` opts `{git_dir, work_tree}`, `staged_summary` keys (`files/added/deleted/changed`), `Configs.get/update`, `TrackedPaths.add/remove/set_ignores/mark_first_backup`, `Runs.create_started/finalize`, `BackupPipeline.run(opts)`, `Scheduler.do_reconcile/schedule_next`, view `status` atoms (`:ok/:pending/:missing`) are used consistently across tasks. ✓

## Out of Scope

Cross-machine sync, branches-per-machine, templating; secret detection/encryption; `.gitignore`-in-folder (v1 uses `info/exclude`); bulk fresh-machine restore wizard; non-Arch package managers; auth (loopback only).

## Open Questions (non-blocking)

- Heroicon for nav: `hero-document-duplicate` proposed (confirm it's in the optimized set).
- Whether "Back up now" should be disabled while a run is in flight (recommend yes, from Oban queue state in the view).
