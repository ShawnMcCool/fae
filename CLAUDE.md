# Fae

Fae is a personal tooling hub that runs as a user systemd service on a single-user Linux desktop. It is a **desktop application that happens to have a web UI**, built in Elixir / Phoenix LiveView. The first tool planned is rotating SQLite backups to Hetzner Object Storage; the current milestone is the walking skeleton.

## Read these first

Architectural and design decisions live in `docs/decisions/` in MADR 4.0 lean format. **Read the Fae-originating decisions before writing code** — they establish the foundational stance, the auth/trust model, and the self-update trust model:

- `docs/decisions/architecture/2026-05-16-027-desktop-application-with-realtime-web-ui.md` — Fae is a desktop app; state lives in supervised processes; the DB is persistence, not source of truth; UI is LiveView + PubSub only; tools are sub-supervisor trees.
- `docs/decisions/architecture/2026-05-16-028-no-application-layer-auth-on-single-user-desktop.md` — no login; loopback-only binding is the trust model; reversal triggers are documented.
- `docs/decisions/architecture/2026-05-16-029-self-update-via-public-github-releases.md` — self-update polls public GitHub Releases, verifies SHA256, runs a detached installer; trust is anchored to TLS + GitHub account; no GPG signing in v1, but reversal triggers documented.
- `docs/decisions/architecture/2026-05-30-032-dotfiles-bare-repo-in-place.md` — the Dotfiles tool: bare-repo-in-place auto-backup of config to a per-machine GitHub repo (work-tree = `$HOME`, no symlinks); replaces dot-filer.

The remaining decisions in `docs/decisions/` originated in the central library at `~/src/decisions/` and were imported for relevance to Fae. Categories:

- `architecture/` — language-agnostic principles (bounded contexts, code quality, testing, no magic numbers)
- `architecture/elixir/` — Elixir/OTP/Phoenix/LiveView (real-time PubSub pattern, OTP supervision, LiveView logic extraction)
- `ui/` — visual conventions (file path display, semantic colors, durations, baseline alignment, inline content)

New Fae-specific decisions land here first and may later be harvested into `~/src/decisions/` via `/harvest-decisions`.

## Architecture summary

- Elixir + Phoenix LiveView (no controllers in the application surface)
- `Phoenix.PubSub` for live state propagation between supervised processes and LiveViews
- Ecto + SQLite (Exqlite) for durable persistence — *not* source of truth
- `mix release` packaged as a systemd user unit
- Binds **`127.0.0.1` only** — this is enforced in `runtime.exs`; the trust model depends on it

## Build, install, run, release

```
bin/build      # produces _build/prod/rel/fae (assets + release + tarball)
bin/install    # copies release to ~/.local/opt/fae, installs systemd unit, enables, starts
bin/release    # cuts a GitHub release at v<version-in-mix.exs> (manual publish flow)
```

After install:

```
systemctl --user status fae
journalctl --user -u fae -f
```

Then open <http://127.0.0.1:4321>.

The systemd unit lives at `rel/overlays/share/systemd/fae.service` and is bundled into the release tree at `share/systemd/fae.service`. The release tree also includes:

- `bin/server` (from `rel/overlays/bin/server`) — wrapper that sets `PHX_SERVER=true` and starts the release.
- `bin/fae-install` (from `rel/overlays/bin/fae-install`) — installer script executed by `Fae.SelfUpdate.Handoff` after the in-app updater stages a new release. Stops the running unit, swaps the install dir, refreshes the systemd unit, and starts the new release. Also usable directly (`bin/fae-install`) from a staged tree for manual installs.

The first boot in production auto-generates and persists a `secret_key_base` at `~/.local/share/fae/secret_key_base` (mode 0600).

## Filesystem layout (XDG)

- App DB: `~/.local/share/fae/fae.db`
- Config: `~/.config/fae/` (reserved)
- Logs: `~/.local/state/fae/`
- Cache: `~/.cache/fae/`

## Repo layout

```
lib/fae/                    # domain: contexts, supervisors, GenServers
lib/fae_web/                # web: endpoint, router, LiveViews
lib/fae_web/live/           # LiveView modules (one file per page)
docs/decisions/             # decision records
priv/repo/migrations/       # Ecto migrations
rel/overlays/               # release overlays (systemd unit, etc.)
config/                     # build-time + runtime config
```

## Conventions worth knowing up front

- Tests are first-class; test-first, append-only regressions, no warnings (`docs/decisions/architecture/2026-02-27-002-code-quality-standards.md`)
- Every LiveView subscribes to PubSub for real-time updates (`docs/decisions/architecture/elixir/2026-03-02-015-liveviews-must-be-realtime.md`)
- LiveView logic is extracted to public pure functions with async unit tests (`docs/decisions/architecture/elixir/2026-04-02-019-liveview-logic-extraction.md`)
- OTP discipline: explicit `max_restarts`, sub-supervisors for restart dependencies, durable process design (`docs/decisions/architecture/elixir/2026-03-03-008-otp-process-design.md`)
- No magic numbers; no abbreviations in identifiers (`docs/decisions/architecture/2026-03-03-005-no-magic-numbers.md`)
- Single-writer ownership for shared state; cross-context interaction via PubSub (`docs/decisions/architecture/2026-02-20-006-bounded-contexts-and-state-ownership.md`)

Read the full decisions when making architectural changes.
