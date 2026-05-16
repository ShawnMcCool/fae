# Fae

Fae is a personal tooling hub that runs as a user systemd service on a single-user Linux desktop. It is a **desktop application that happens to have a web UI**, built in Elixir / Phoenix LiveView. The first tool planned is rotating SQLite backups to Hetzner Object Storage; the current milestone is the walking skeleton.

## Read these first

Architectural and design decisions live in `docs/decisions/` in MADR 4.0 lean format. **Read the two Fae-originating decisions before writing code** — they establish the foundational stance and the auth/trust model:

- `docs/decisions/architecture/2026-05-16-027-desktop-application-with-realtime-web-ui.md` — Fae is a desktop app; state lives in supervised processes; the DB is persistence, not source of truth; UI is LiveView + PubSub only; tools are sub-supervisor trees.
- `docs/decisions/architecture/2026-05-16-028-no-application-layer-auth-on-single-user-desktop.md` — no login; loopback-only binding is the trust model; reversal triggers are documented.

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

## Build, install, run

```
bin/build      # produces _build/prod/rel/fae (assets compiled, release assembled)
bin/install    # copies release to ~/.local/opt/fae, installs systemd unit, enables, starts
```

After install:

```
systemctl --user status fae
journalctl --user -u fae -f
```

Then open <http://127.0.0.1:4321>.

The systemd unit lives at `contrib/systemd/fae.service`. The release tree includes a `bin/server` wrapper (from `rel/overlays/bin/server`) that sets `PHX_SERVER=true` and starts the release. The first boot in production auto-generates and persists a `secret_key_base` at `~/.local/share/fae/secret_key_base` (mode 0600).

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
