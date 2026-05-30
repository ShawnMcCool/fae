# Fae Dotfiles — Design

- **Date:** 2026-05-30
- **Status:** Approved (design); ready for implementation planning
- **Author:** Shawn McCool (with Claude)

## Context

Today, dotfiles are managed by `dot-filer` (a PHP CLI) wrapped in
`~/scripts/dotfiles/dotfiler` (zsh) and nudged by a systemd timer. Its model:
for each path in `target.paths`, it **moves** the real file into
`~/src/dotfiles/files/...` and leaves a **symlink** at the original location.
Git tracks the repo folder; a timer reminds the user to commit + push, and the
`commit` action also regenerates `package-list.txt` (all installed Arch
packages).

This works but has friction: the symlink indirection is fragile for single-file
targets (atomic-save replaces the symlink with a regular file), backup is a
non-atomic move (`rename` then `symlink`), there is no live visibility, and the
commit/push step is manual.

Fae is a desktop application with an always-on supervised runtime and a realtime
LiveView UI — exactly the missing ingredient that makes a *set-and-forget*
dotfiles tool ergonomic. This document specifies a Fae tool that replaces
dot-filer.

## Goals

- Curate a set of tracked config paths from a friendly UI (add / remove / ignore).
- Automatically back up everything tracked on a configurable timer — no manual
  per-file or per-folder commit work in normal use.
- Show health (is it on, last/next backup, push status) and a backup history.
- Restore tracked files onto a machine (disaster recovery / fresh setup).
- Replace dot-filer, its wrapper, and its timer entirely.

## Non-goals

- **No cross-machine sync.** The user runs two **entirely separate setups**.
  Each machine has its own repo, its own remote, its own configs. Machines never
  sync, share branches, or merge. (This removes any need for templating,
  machine-specific layering, or conflict resolution.)
- No application-layer auth (Fae is loopback-only; see decision 028).
- No secret management story in v1 — secrets are handled outside this tool and
  are simply not tracked.

## Storage model — bare repo, files in place

The defining decision: **drop symlinks entirely.** Use a bare git repository
whose work-tree is `$HOME`.

- A bare git directory is owned by Fae under XDG data
  (e.g. `~/.local/share/fae/dotfiles/repo.git`).
- Every git operation runs with `--git-dir=<that>` and `--work-tree=$HOME`.
  Tracked config files therefore stay **real and in their actual locations**
  (`~/.config/nvim`, `~/.gitconfig`, …) while git tracks them in place. No move,
  no symlink, no copy. The file the app reads and the file git tracks are the
  same inode at the same path.
- **Restore** on a fresh machine is `git clone --bare` + `git checkout` into
  `$HOME` — no symlinks to recreate.

Why this over the old symlink model:

- Atomic-save (write-temp + `rename`) by editors/apps can no longer silently
  de-manage a single-file target — there is no symlink to clobber.
- No non-atomic move window; worst case is a failed `git add`.
- It directly dissolves the reason symlinks existed: the repo was a *separate
  folder*. With work-tree = `$HOME`, "in the repo" and "where it belongs" are
  the same place.

### Folder-as-unit tracking

Git's unit is the file, but the tool always operates at folder granularity:

- Tracking a folder means `git add -A -- <folder>`: the commit matches the
  folder's **current** contents. Files that appear are included; files that
  vanish are recorded as deletions. Dynamic folders "just work."
- New files inside a tracked folder must still enter history via `git add` — the
  backup cycle does this automatically with `git add -A` over the tracked roots.

### Ignores (carving churn out of a tracked folder)

Folders often mix wanted config with churn (`fish_history`, caches, lock/state
files). Two supported mechanisms:

1. A real `.gitignore` inside the folder (tracked, travels on restore) — for
   exclusions intrinsic to that config.
2. The repo's `info/exclude` (machine-local, not committed) — for machine-local
   junk.

The UI lets the user view what's ignored in a folder and add patterns.

### Keeping `$HOME` noise out of the UI

Because the work-tree is all of `$HOME`, naive `git status` would list the whole
home directory. Handled by:

- `git config --local status.showUntrackedFiles no`, and
- **always** querying scoped to tracked roots:
  `git ... status --porcelain --untracked-files=all -- <root1> <root2> ...`.
  This surfaces modified/new/deleted files *inside tracked folders* while hiding
  everything else in `$HOME`.

## Scheduling — set-and-forget, suspend-safe

- **Configurable cadence** (default: hourly).
- The timer is **interval-since-last-success**, not a wall-clock cron. The
  scheduler stores the timestamp of the last successful backup and computes the
  next run as `last_success + interval`. On wake from suspend, if the machine
  has been asleep past the interval, it runs **once** when due — never a flurry
  of catch-up runs, and a long gap is normal, not an error.
- Each cycle:
  1. Scoped change scan over tracked roots.
  2. Regenerate `package-list.txt` (this machine's installed packages).
  3. If anything changed (config or package list): `git add -A -- <roots>`,
     commit, push.
  4. If nothing changed: record a lightweight "checked, no changes" heartbeat
     (timestamp only) — **no empty commit**.
- **Push failures** (offline, auth, remote ahead) are non-fatal: the local
  commit still exists, the cycle retries next interval, and the failure is
  surfaced in the health strip only if it persists.

## Per-machine independence

- Each machine = its own bare repo + its own GitHub remote, default repo name
  `dotfiles-<hostname>` (configurable in Fae settings).
- The existing `github.com/ShawnMcCool/dotfiles` repo is left as an archive;
  each machine starts a fresh history with the new in-place layout.
- No branches-per-machine, no shared state. Two separate setups.

## Curation semantics

- **Track a path:** add a root to the tracked set; it is `git add`-ed on the
  next backup cycle (consider an immediate first backup on add — deferred to
  planning).
- **Stop tracking:** `git rm --cached -r <root>` — the real file stays on disk,
  it just stops being tracked/backed up.
- **Missing path** (a tracked path deleted on disk): surfaced with a red marker;
  actions are Restore (`git checkout`) or Stop tracking.
- **Manage ignores:** edit the folder's ignore patterns.

## UI (LiveView, daisyUI dark theme, realtime via PubSub)

Mockups: `.superpowers/brainstorm/.../content/` (board-v3, add-path).

- **Health strip** — single line: on/off toggle, cadence dropdown, last backup +
  push status, next-in countdown, "Back up now". Turns loud (warning/error) only
  when a push fails or a path is broken.
- **Tracked paths** — minimal grouped list, two columns. The repeated parent
  prefix (`~/.config/`) is hoisted into a group header; each path is a single
  tight line. A colored dot appears **only** when something is off (info =
  pending first backup, error = missing on disk). Tiny sub-note only when
  meaningful (e.g. `1 ignored`). Hover reveals a `⋯` menu (Manage ignores, Stop
  tracking). Steady state reads like `ls`.
- **Add path** — three paths of decreasing friction:
  1. ✨ **Suggestions**: Fae scans `~/.config` and surfaces directories not yet
     tracked as one-click pills.
  2. **Checkbox file browser**: navigate `$HOME`, tick folders/files;
     already-tracked entries are dimmed and tagged.
  3. **Manual path field** for anything outside the obvious spots.
- **Recent backups** — run history: timestamp, change summary, package delta,
  push status, optional diff link. "No changes" cycles appear faintly as a
  heartbeat.

## Migration — guided import, once per machine

A one-time in-app "Import existing dotfiles" flow:

1. Read dot-filer's `target.paths`.
2. Show a preview of what will be de-referenced.
3. Make a safety copy of the current state.
4. For each tracked path: replace the symlink with its real file **in place**
   (the real bytes currently live in `~/src/dotfiles/files/...`; copy them to the
   real `$HOME` location and remove the symlink).
5. Init the bare repo (work-tree = `$HOME`), set `status.showUntrackedFiles no`,
   `git add` the tracked roots, commit.
6. Create/attach the `dotfiles-<hostname>` remote, push.
7. Disable the old systemd timer so there are no double-backups.

## Architecture (Fae conventions)

Per decisions 027 (desktop app / supervised state / DB-as-persistence), 028
(loopback, no auth), 006 (single-writer ownership), 008 (OTP discipline), 019
(LiveView logic extraction), 015 (realtime LiveViews).

- **Sub-supervisor** for the Dotfiles tool with explicit `max_restarts`.
- A **single-writer GenServer** owns scheduler state and serializes all backup
  operations (the only writer to the repo). It computes interval-since-success,
  runs cycles, and broadcasts status changes over `Phoenix.PubSub`.
- A **git-operations module** wrapping the bare repo (git-dir/work-tree flags) —
  pure-ish, dependency-injectable, unit-testable (scan, add, commit, push,
  status, checkout, rm --cached).
- A **package-list module** that produces this machine's installed-package
  manifest.
- **Ecto/SQLite** persists configuration (tracked roots, cadence, remote, ignore
  metadata) and run history — *not* the source of truth. The repo + live files
  are the truth; the GenServer holds runtime state.
- **LiveView** subscribes to the tool's PubSub topic and re-renders on every
  event; view-shaping logic extracted to pure functions with async unit tests.

## Error handling

- Push failure: keep local commit, retry next cycle, surface only if persistent.
- Missing tracked path: mark broken; never block other paths' backup.
- Migration: safety copy first; abort cleanly with the copy intact on any error.
- Suspend/clock jumps: handled by interval-since-success; long gaps are normal.

## Testing strategy

Test-first, no warnings (decision 002). Unit-test the git-operations module
against a temp repo, the scheduler's interval-since-success logic (including
simulated long gaps), the package-list module, and the pure view functions.
Integration-test a full backup cycle end to end.

## Deferred to planning

- Exact git-dir location under `~/.local/share/fae/`.
- Whether "Track a path" triggers an immediate first backup or waits for the
  next cycle.
- The precise package-list command (reuse `~/scripts/arch/list-all-installed-packages`
  vs. a self-contained `pacman -Qqe`).
- Restore UX beyond the single-path case (full fresh-machine restore flow).
