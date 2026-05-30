---
status: accepted
date: 2026-05-30
---
# Dotfiles tool: bare repo with work-tree = $HOME, no symlinks

## Context and Problem Statement

Dotfiles on this machine are managed by `dot-filer` (a PHP CLI wrapped in a zsh script, nudged by a systemd timer). Its model **moves** each tracked file into a separate repo folder (`~/src/dotfiles/files/...`) and leaves a **symlink** at the original location; the timer reminds the operator to commit + push by hand.

That model has structural friction. The symlink indirection is fragile for single-file targets: editors and apps that atomic-save (write a temp file, then `rename` over the target) replace the symlink with a regular file, silently de-managing it. The backup itself is a non-atomic move (`rename` then `symlink`) with a window where neither the real file nor the link is where it should be. There is no live visibility, and the commit/push step is manual, so the working tree drifts from the remote between the operator's attention.

Fae is a desktop application with an always-on supervised runtime and a realtime LiveView UI ([[027-desktop-application-with-realtime-web-ui]]) — exactly the missing ingredient that makes a *set-and-forget* dotfiles tool ergonomic. The question was how to track config under Fae without inheriting dot-filer's symlink fragility, and how to make backup automatic and suspend-resilient on a single-user desktop. Full design: `docs/superpowers/specs/2026-05-30-fae-dotfiles-design.md`.

## Decision Outcome

Chosen option: **build a `Fae.Dotfiles` tool that tracks config with a bare git repo whose work-tree is `$HOME` — files stay real and in place, no symlinks — backed up automatically by a self-rescheduling Oban worker on an interval-since-last-success timer, per-machine and folder-as-unit; retire dot-filer via a guided in-app import.** Per [[027-desktop-application-with-realtime-web-ui]] it is its own supervised subtree with a single-writer scheduler GenServer over the repo, SQLite for config + run history (not the source of truth), and a realtime LiveView.

### Bare repo, files in place — no symlinks

A bare git directory is owned by Fae under XDG data; every git operation runs with `--git-dir=<that>` and `--work-tree=$HOME`. Tracked config files therefore stay **real and in their actual locations** (`~/.config/nvim`, `~/.gitconfig`, …) while git tracks them in place — no move, no symlink, no copy. The file the app reads and the file git tracks are the same inode at the same path. This is the defining choice and the reason to replace dot-filer rather than wrap it: atomic-save can no longer clobber a symlink because there is none; there is no non-atomic move window (worst case is a failed `git add`); and the very reason symlinks existed — the repo being a *separate folder* — dissolves, since with work-tree = `$HOME` "in the repo" and "where it belongs" are the same path. Restore on a fresh machine is `git clone --bare` + `git checkout` into `$HOME`, with no symlinks to recreate.

Because the work-tree is all of `$HOME`, naive `git status` would list the whole home directory. This is handled by `status.showUntrackedFiles no` plus **always** scoping queries to the tracked roots (`status --porcelain --untracked-files=all -- <roots>`), so only changes inside tracked folders surface.

### Per-machine, separate repos — no cross-machine sync

The operator runs two **entirely separate setups**. Each machine gets its own bare repo and its own GitHub remote (default `dotfiles-<hostname>`, configurable in Fae settings); machines never sync, share branches, or merge. This removes any need for templating, machine-specific layering, or conflict resolution — explicitly out of scope, not deferred. A per-machine `package-list.txt` (`pacman -Qqe`) is committed each backup so a fresh setup can be reconstructed.

### Set-and-forget scheduling via a self-rescheduling Oban worker

Backup runs on a configurable cadence (default hourly) via an Oban worker that, at the end of each run, **self-reschedules at `now + interval`** — an interval-since-last-success timer, not a wall-clock cron. Suspend-resilience falls out for free: Oban runs the single overdue scheduled job once on resume rather than a flurry of catch-up runs, so a long gap is normal, not an error. Each cycle scans the tracked roots, regenerates the package manifest, and — only if something changed — `git add -A`s the roots, commits, and pushes; an unchanged cycle records a timestamp-only heartbeat with no empty commit. Push failures (offline, auth, remote ahead) are non-fatal: the local commit stands, the next interval retries, and the failure surfaces in the health strip only if it persists.

### Folder-as-unit tracking; machine-local ignores in v1

The tool operates at folder granularity even though git's unit is the file: tracking a folder is `git add -A -- <folder>`, so each commit matches the folder's current contents (files that appear are included, files that vanish are recorded as deletions) and dynamic folders just work. Ignores in v1 live in the repo's `info/exclude` (machine-local, not committed) — appropriate because the repos are per-machine anyway. Tracked-in `.gitignore` files inside a folder still work for exclusions intrinsic to a config, but the UI's ignore management targets `info/exclude`.

### Retiring dot-filer via guided import

dot-filer, its wrapper, and its timer are retired. A one-time in-app "Import existing dotfiles" flow reads dot-filer's `target.paths`, makes a safety copy, **de-references each symlink in place** (copies the real bytes from `~/src/dotfiles/files/...` back to the `$HOME` location and removes the link), inits the bare repo, commits, pushes, and **disables the old systemd timer** so there are no double-backups. On any error it aborts cleanly with the safety copy intact.

### What's deferred (YAGNI)

Cross-machine sync, templating, and secret management are out of scope by design. A full fresh-machine restore UX (beyond the single-path Restore action), and whether "Track a path" triggers an immediate first backup vs. waiting for the next cycle, are deferred to planning.

### Reversal triggers

- If the operator ever wants config shared across machines, this whole per-machine stance reopens — that is a different tool, not a setting.
- If churn in tracked folders needs exclusions that should travel on restore, revisit committing `.gitignore` as the primary ignore mechanism rather than `info/exclude`.
- If secrets must be tracked, that requires a real secret-management story (and likely reopening what loopback-only trust covers under [[028-no-application-layer-auth-on-single-user-desktop]]).

## Consequences

* Good, because tracked files are real and in place — atomic-save can no longer silently de-manage a single-file target, and there is no non-atomic move window.
* Good, because "in the repo" and "where it belongs" are the same path, removing the indirection that made symlinks necessary; restore is a plain `clone` + `checkout` into `$HOME`.
* Good, because backup is genuinely set-and-forget: the self-rescheduling worker runs unattended, survives suspend without catch-up storms, and never produces empty commits.
* Good, because per-machine repos eliminate templating, layering, and conflict resolution entirely — the two setups stay independent by construction.
* Good, because it follows the standard Fae tool shape (supervised subtree + single-writer GenServer + PubSub + LiveView), reusing the realtime/observability story rather than inventing one.
* Bad, because a `$HOME` work-tree means every git query must be carefully scoped to tracked roots; an unscoped command would treat the entire home directory as the working tree.
* Bad, because machine-local `info/exclude` ignores do not travel on restore, so a fresh machine re-derives them (acceptable given per-machine independence).
* Bad, because retiring dot-filer is a one-way migration per machine — the import de-references symlinks in place and disables the old timer, so rollback means restoring from the safety copy.
* Neutral, because the existing `ShawnMcCool/dotfiles` repo is left as an archive; each machine starts a fresh history under the new in-place layout.
