# Fae Dotfiles — Implementation Plan

## Goal

Ship a `Fae.Dotfiles` tool that auto-backs-up a curated set of `$HOME` config
paths to this machine's own GitHub repo on a suspend-safe timer, with a LiveView
board for curation, health, and history — replacing dot-filer.

## Context

**Design spec:** `docs/superpowers/specs/2026-05-30-fae-dotfiles-design.md` (read
it first). **UI mockups:** `.superpowers/brainstorm/*/content/board-v3.html`,
`add-path.html` (gitignored).

**Storage model:** bare git repo, work-tree = `$HOME`, files tracked in place
(no symlinks). Per-machine: own repo, own remote, no sync.

**Mirror these existing modules exactly (same shape, same conventions):**

- Scheduler: `lib/fae/backups/scheduler.ex` — GenServer, `Process.send_after`
  tick, calls a pure `Schedule.due?`, fires via a `RunSupervisor`.
- Pure schedule math: `lib/fae/backups/schedule.ex` — `due?/2` uses
  `last_run_at + interval`. Already interval-since-last-run (suspend-safe).
- Run execution: `lib/fae/backups/run_supervisor.ex` (DynamicSupervisor) +
  `lib/fae/backups/run_worker.ex` (transient GenServer, `handle_continue(:run)`,
  `Runs.create_started` → execute → finalize → broadcast).
- Schemas: `lib/fae/backups/job.ex`, `run.ex` — `Ecto.Schema`, `Ecto.Enum`,
  `changeset/2`, `timestamps(type: :utc_datetime)`.
- Context facade: `lib/fae/backups.ex` delegating to `Jobs`/`Runs`/`Schedule`.
- Context queries: `lib/fae/backups/jobs.ex`, `runs.ex` — `import Ecto.Query`,
  `Fae.Repo`, broadcast on writes.
- Topics: `lib/fae/topics.ex` — central topic + broadcast helpers.
- Clock: `lib/fae/clock.ex` — use `Fae.Clock.now()` everywhere (injectable).
- Application children: `lib/fae/application.ex` (one_for_one).
- Web nav: `lib/fae_web/components/layouts.ex` `@nav_items`.
- LiveView: `lib/fae_web/live/backups_live/index.ex` (mount→subscribe→load,
  `handle_info`→reload, `render` wraps `<Layouts.app>`).
- Pure view module: `lib/fae_web/live/dashboard_view.ex`.
- Router: `lib/fae_web/router.ex` `live_session :default`.

**Decisions to honor:** 027 (supervised state; DB is persistence, not truth),
028 (loopback only, no auth), 006 (single-writer), 008 (explicit `max_restarts`,
sub-supervisors), 019 (extract LiveView logic to pure funcs), 015 (LiveViews
realtime via PubSub), 002 (test-first, no warnings).

**Git invocation:** all git runs as
`System.cmd("git", ["--git-dir", git_dir, "--work-tree", work_tree | args],
env: [{"GIT_TERMINAL_PROMPT", "0"}], stderr_to_stdout: true)`. Never hardcode
paths inside the Git module — accept `git_dir`/`work_tree` so tests use temp
dirs.

**Paths (new `Fae.Dotfiles.Paths` module, values from app env so tests
override):**
- git-dir: `Path.join(data_dir, "dotfiles/repo.git")`
- work-tree: `System.user_home!()`
- package manifest: `<work_tree>/.config/fae/package-list.txt`
- Add to `config/runtime.exs`: `config :fae, Fae.Dotfiles, git_dir: …,
  work_tree: …` (test config in `config/test.exs` points at `tmp/`).

**Out-of-the-box behaviors decided during planning:**
- `due?` is interval-since-`last_checked_at` (a cycle always updates
  `last_checked_at`; long suspend gaps just make it due once on resume).
- A cycle always: stage → commit-if-staged → push-if-ahead. Push failure is
  non-fatal; the unpushed commit is retried next cycle. Manifest is regenerated
  and staged every cycle.
- "Track a path" does **not** trigger an immediate backup; it lands in the next
  cycle (matches set-and-forget; avoids surprise writes). A manual "Back up now"
  exists for impatience.
- Ignores in v1 are stored as patterns on the tracked path and written to the
  repo's `info/exclude` (machine-local) before each stage. `.gitignore`-in-folder
  is deferred.

## Data model

Three tables (migrations in `priv/repo/migrations/`, schemas in
`lib/fae/dotfiles/`):

- `dotfiles_tracked_paths`: `path:string` (absolute, unique), `kind:enum
  [:directory,:file]`, `ignore_patterns:string` (newline-sep, nullable),
  `first_backed_up_at:utc_datetime?`, timestamps.
- `dotfiles_runs`: `status:enum [:running,:success,:no_changes,:error]`,
  `started_at`, `finished_at`, `files_changed:int`, `files_added:int`,
  `files_deleted:int`, `packages_added:int?`, `packages_removed:int?`,
  `commit_sha:string?`, `pushed:boolean default false`, `error_message:string?`,
  timestamps.
- `dotfiles_config` (singleton, fixed `id=1`): `enabled:boolean default true`,
  `interval_seconds:int default 3600`, `remote_url:string?`, `remote_name:string
  default "origin"`, `branch:string default "main"`, `last_checked_at:utc_datetime?`,
  `last_backup_at:utc_datetime?`, `last_push_ok:boolean default true`,
  `last_push_error:string?`, `initialized:boolean default false`, timestamps.

---

## Steps

### Step 1: Migrations + schemas + config singleton

**Files:** `priv/repo/migrations/<ts>_create_dotfiles.exs`,
`lib/fae/dotfiles/tracked_path.ex`, `lib/fae/dotfiles/run.ex`,
`lib/fae/dotfiles/config.ex`, plus tests under `test/fae/dotfiles/`.

**Changes:** One migration creating the three tables above (unique index on
`dotfiles_tracked_paths.path`). Three `Ecto.Schema` modules mirroring
`backups/job.ex` style with `changeset/2`. `Config` gets a fixed-id singleton
pattern.

**Acceptance:** `mix ecto.migrate` succeeds; schema changeset tests pass
(valid/invalid cases for each); `mix compile --warnings-as-errors` clean.

### Step 2: `Fae.Dotfiles.Paths`

**Files:** `lib/fae/dotfiles/paths.ex`, `config/runtime.exs` (add `config :fae,
Fae.Dotfiles, git_dir:, work_tree:`), `config/test.exs` (tmp paths),
`test/fae/dotfiles/paths_test.exs`.

**Changes:** `git_dir/0`, `work_tree/0`, `manifest_path/0`, `manifest_relpath/0`
reading `Application.get_env(:fae, Fae.Dotfiles)`.

**Acceptance:** test asserts values come from app env and test env points at
`tmp/`.

### Step 3: `Fae.Dotfiles.Git` (shell-out wrapper)

**Files:** `lib/fae/dotfiles/git.ex`, `test/fae/dotfiles/git_test.exs`.

**Changes:** Functions, each accepting `git_dir`/`work_tree` (default from
`Paths`): `init_bare/1`, `configure/1` (sets `status.showUntrackedFiles=no`,
user name/email if unset), `set_remote/3`, `write_exclude/2`, `stage/2`
(`add -A -- <roots> <manifest>`), `staged_summary/1` (parse `diff --cached
--numstat` → %{changed, added, deleted, files}), `commit/2` →
`{:ok, sha} | {:nochange}`, `ahead_of_remote?/1`, `push/3` →
`:ok | {:error, msg}`, `head_sha/1`, `status/2` (parse `--porcelain
--untracked-files=all -- <roots>`), `ls_files/2`, `rm_cached/2`, `checkout/2`,
`current_branch/1`. Return tagged tuples; never raise on nonzero git exit.

**Acceptance:** tests run against a real temp git-dir + temp work-tree (create
files, stage, commit, assert `head_sha`, `staged_summary`, `status` parsing,
`rm_cached` leaves the file on disk). No network (push tested via a local
`--bare` repo as remote). Clean compile.

### Step 4: `Fae.Dotfiles.Schedule` (pure)

**Files:** `lib/fae/dotfiles/schedule.ex`, `test/fae/dotfiles/schedule_test.exs`.

**Changes:** `due?(%Config{}, now)` = enabled and (`last_checked_at` nil or
`DateTime.diff(now, last_checked_at) >= interval_seconds`). `next_fire(config)`
for display. Pure; uses passed-in `now`.

**Acceptance:** unit tests incl. never-checked (due), within-interval (not due),
past-interval, **suspend gap** (last_checked 5h ago, interval 1h → due exactly
once), disabled (never due).

### Step 5: `Fae.Dotfiles.PackageList`

**Files:** `lib/fae/dotfiles/package_list.ex`,
`test/fae/dotfiles/package_list_test.exs`.

**Changes:** `generate/0` runs `pacman -Qqe` (via an injectable command fn,
default `System.cmd`), returns sorted package names as a string.
`write!/1` writes to `Paths.manifest_path()` (mkdir_p the parent).

**Acceptance:** test injects a fake command returning sample output, asserts
sorted manifest content and that the file is written to the configured tmp path.

### Step 6: Context + queries (`Tracked_paths`, `Runs`, `Config`, facade)

**Files:** `lib/fae/dotfiles/tracked_paths.ex`, `lib/fae/dotfiles/runs.ex`,
`lib/fae/dotfiles/configs.ex` (get/update singleton), `lib/fae/dotfiles.ex`
(facade), tests for each.

**Changes:** mirror `backups/jobs.ex`+`runs.ex`. `TrackedPaths`: `list/0`,
`add/1` (path+kind, broadcast), `remove/1`, `set_ignores/2`, `mark_first_backup/1`.
`Runs`: `create_started/0`, `finalize/2`, `last/0`, `list_recent/1`. `Configs`:
`get/0` (create singleton if missing), `update/1`, setters for
`last_checked_at`/`last_backup_at`/push state. Facade delegates. All writes
broadcast via new Topics helpers (Step 7).

**Acceptance:** context tests (DataCase) for add/remove/list, run lifecycle,
config get-or-create + update. Clean compile.

### Step 7: Topics

**Files:** `lib/fae/topics.ex` (extend), `test/fae/topics_test.exs` (if exists).

**Changes:** add `@dotfiles_status "dotfiles:status"`, `@dotfiles_runs
"dotfiles:runs"`, accessors, and `broadcast_dotfiles_status/1`,
`broadcast_dotfiles_runs/1`.

**Acceptance:** compile + a broadcast/subscribe round-trip test.

### Step 8: RunSupervisor + RunWorker (the backup cycle)

**Files:** `lib/fae/dotfiles/run_supervisor.ex`, `lib/fae/dotfiles/run_worker.ex`,
`test/fae/dotfiles/run_worker_test.exs`.

**Changes:** `RunSupervisor` = DynamicSupervisor (copy backups, `max_restarts:
3`). `RunWorker` (transient GenServer, `handle_continue(:run)`): create run →
broadcast → `PackageList.write!` → `Git.write_exclude` (from all tracked
ignores) → `Git.stage(roots ++ manifest)` → `Git.staged_summary` → if nothing
staged: finalize `:no_changes`, update `last_checked_at` → else `Git.commit` →
`Git.push` (capture ok/err) → finalize `:success` with counts/sha/pushed,
update `last_backup_at`/push state → also: if not staged but
`Git.ahead_of_remote?` (prior push failed), attempt push → always set
`last_checked_at` → broadcast run + status → `{:stop, :normal}`. Mark
`first_backed_up_at` for paths included in their first successful commit.

**Acceptance:** `run_worker_test` against temp repo + fake home + local bare
remote: seed a tracked dir, run worker, assert a commit exists, run record is
`:success` with correct counts, manifest committed, `last_backup_at` set; a
second run with no changes records `:no_changes` and no new commit; a run with
an unreachable remote records `pushed: false` but still commits and sets
`last_push_error`.

### Step 9: Scheduler

**Files:** `lib/fae/dotfiles/scheduler.ex`, `test/fae/dotfiles/scheduler_test.exs`.

**Changes:** copy backups Scheduler. Tick (60s). On tick: if `Config.initialized`
and `Schedule.due?(Configs.get(), Clock.now())` and no run currently in
`RunSupervisor` (guard concurrent), call `RunSupervisor.start_run/0`. (No-op
until migration has initialized the repo.)

**Acceptance:** test drives `check_and_fire` directly with a stubbed Clock to
assert it fires when due and skips when not / when uninitialized.

### Step 10: Wire into Application supervision

**Files:** `lib/fae/application.ex`, `test/fae/application_test.exs` (smoke).

**Changes:** add `Fae.Dotfiles.RunSupervisor` and `Fae.Dotfiles.Scheduler` to
children (after the backups entries).

**Acceptance:** app boots in test; both processes alive; `mix test` green.

### Step 11: Suggestions

**Files:** `lib/fae/dotfiles/suggestions.ex`,
`test/fae/dotfiles/suggestions_test.exs`.

**Changes:** `untracked_in/1` (default `~/.config`): list child entries (dirs +
files) not already tracked, sorted. Takes base dir + tracked list for purity.

**Acceptance:** test against a tmp dir with some entries tracked, some not.

### Step 12: View module (pure) + Topics-driven LiveView board

**Files:** `lib/fae_web/live/dotfiles_view.ex`,
`lib/fae_web/live/dotfiles_live/index.ex`, `test/fae_web/live/dotfiles_view_test.exs`,
`test/fae_web/live/dotfiles_live_test.exs`.

**Changes:** `DotfilesView.build/1` shapes: health (on/off, cadence label, last
backup relative, push status, next-in), grouped tracked paths (group by parent
dir, mark `:pending`/`:missing`/`:ok` by checking `File.exists?` + db
`first_backed_up_at`), recent runs. `DotfilesLive.Index` mirrors
`backups_live/index.ex`: subscribe to `dotfiles:status` + `dotfiles:runs`,
`load` builds view via `DotfilesView`, render per `board-v3.html` using daisyUI
+ `<Layouts.app>`. Events: `toggle_enabled`, `set_cadence`, `backup_now`
(`RunSupervisor.start_run`), `stop_tracking`, `restore_path`.

**Acceptance:** view tests assert grouping + status classification (incl. a
missing path). LiveView test mounts, shows tracked paths, `backup_now` triggers
a run, PubSub broadcast re-renders. Pure-function logic lives in `DotfilesView`.

### Step 13: Add-path flow + ignore management (LiveComponents)

**Files:** `lib/fae_web/live/dotfiles_live/track_path_component.ex`,
`lib/fae_web/live/dotfiles_live/ignores_component.ex`, tests.

**Changes:** Track-path modal per `add-path.html`: ✨ suggestions
(`Suggestions.untracked_in`), checkbox file browser (`File.ls` navigation, mark
already-tracked), manual path field; submit → `TrackedPaths.add` for each.
Ignores modal: edit patterns → `TrackedPaths.set_ignores`.

**Acceptance:** component tests: suggestions render and add; browser navigates
and disables tracked entries; manual add validates path exists; ignores persist.

### Step 14: Nav + router

**Files:** `lib/fae_web/components/layouts.ex` (`@nav_items`),
`lib/fae_web/router.ex`.

**Changes:** add `%{label: "Dotfiles", path: "/dotfiles", icon: "hero-document-duplicate"}`
to nav (after Backups). Add `scope "/dotfiles" do live "/", DotfilesLive.Index,
:index end` in `live_session :default`.

**Acceptance:** nav link renders active on `/dotfiles`; route resolves; existing
router tests still pass.

### Step 15: Dashboard integration (optional surface)

**Files:** `lib/fae_web/live/dashboard_live.ex`, `dashboard_view.ex`.

**Changes:** add a compact "Dotfiles" section (last backup, push status, # paths)
subscribing to `dotfiles:status`. Follows existing section pattern.

**Acceptance:** dashboard shows dotfiles health; updates live on a run.

### Step 16: Migration / guided import

**Files:** `lib/fae/dotfiles/migration.ex`,
`lib/fae_web/live/dotfiles_live/import_component.ex`, tests.

**Changes:** `Migration.preview/1` reads `~/src/dotfiles/target.paths`, resolves
each path's state (symlink-into-old-repo / real / missing). `Migration.run/2`:
safety-copy current state to `<data_dir>/dotfiles/import-backup-<ts>/`; for each
symlinked target, replace symlink with real content in place (deref); then
`Git.init_bare` + `configure` + `set_remote` + `stage` all targets + `commit` +
`push`; create `TrackedPath` rows; set `Config.initialized=true`,
`remote_url`. Import LiveView flow: preview → confirm → progress → done.
Disabling the old systemd timer: surface an instruction/command (do not silently
touch the user's systemd units — show the exact `systemctl --user disable
--now` line, or offer a one-click that runs it with confirmation).

**Acceptance:** `migration_test` against a fake home that mimics the
symlink-into-`files/` layout: assert symlinks become real files in place, bare
repo created, all targets committed, `TrackedPath` rows + `Config.initialized`
set, safety copy exists. Re-running is a no-op / guarded.

### Step 17: Retire old tooling (docs) + decision record

**Files:** `docs/decisions/architecture/2026-05-30-0XX-dotfiles-bare-repo-in-place.md`
(MADR lean, capturing: bare-repo-in-place over symlinks, per-machine separate
repos, set-and-forget interval-since-checked scheduler, retire dot-filer),
`CLAUDE.md` (note the new tool), `README`/build docs as needed.

**Changes:** write the decision record; reference the spec. Note dot-filer is
retired (the import disables its timer).

**Acceptance:** decision file present and consistent with the implementation;
`/harvest-decisions` would have something coherent to lift later.

---

## Out of Scope

- Cross-machine sync, branches-per-machine, templating, machine-specific configs.
- Secret detection/encryption (secrets simply aren't tracked).
- `.gitignore`-in-folder ignore mechanism (v1 uses `info/exclude`).
- Full fresh-machine restore wizard (per-path Restore exists; bulk restore later).
- Non-Arch package managers.
- Auth (loopback only, per decision 028).

## Open Questions

None blocking. Confirm during implementation: heroicon name for the nav entry
(`hero-document-duplicate` proposed), and whether the "Back up now" button should
be disabled while a run is in progress (recommend yes, driven by RunSupervisor
child count in the view).
