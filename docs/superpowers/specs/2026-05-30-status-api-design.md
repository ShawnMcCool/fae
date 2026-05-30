# Status API — `GET /api/status` for local consumers

**Date:** 2026-05-30
**Status:** Approved design, pending implementation plan

## Problem

Local processes on the same machine (a quickshell bar/dock, scripts) want to
read Fae's operational state — chiefly: are the backups healthy, when does the
next one fire, is anything failing — without scraping the LiveView dashboard
HTML. They need a stable, machine-readable snapshot they can poll.

## Trust model (no new auth)

This endpoint adds no authentication and needs none:

- Decision-027 explicitly sanctions "health endpoints" as a non-LiveView route;
  user-visible *behavior* stays in LiveView, but incidental read-only HTTP is
  allowed.
- Decision-028: the endpoint binds `127.0.0.1` only (enforced in
  `runtime.exs`). A same-machine consumer like quickshell needs no login. No
  reversal trigger fires — this does not expose Fae beyond loopback and holds
  no new secrets.

The endpoint is **read-only** and **GET-only**.

## Architecture (approach A — shared read-model + decoupled JSON contract)

The dashboard already gathers all of this state inline in
`DashboardLive.refresh/2` and shapes it via the pure `DashboardView.build/1`.
We reuse the *reads* and the *domain derivations*, but give the machine contract
its own presenter so dashboard styling changes never break the API.

Three pure/extracted pieces plus a thin controller:

1. **`Fae.Status.snapshot/0`** (new, domain read-model). Extracts the
   state-gathering currently inline in `DashboardLive.refresh/2` into a single
   reusable function that returns the **raw input map** (jobs, last_runs,
   recent_runs, destinations, version, latest_release, self_update phase/error,
   system, dotfiles, now). Side-effecting reads (Repo, GenServer calls) live
   here and nowhere else.

   - `DashboardLive.refresh/2` becomes: `Fae.Status.snapshot()` → optional
     `:system` override merge → `DashboardView.build/1`. No behavior change.

2. **`Fae.Health`** (new, domain, pure). The four genuinely-domain derivations
   move out of `FaeWeb.DashboardView` into the domain layer so both presenters
   share one source of truth:

   - `health/3` — `(enabled_jobs, last_runs, self_update_phase) -> %{level, reason}`
   - `count_failing/2`
   - `soonest_next_fire/2`
   - `classify_update/3` — the self-update state classification (was the private
     `classify_self_update/3` in `DashboardView`)

   `FaeWeb.DashboardView` keeps these names as **thin delegates** to
   `Fae.Health`, so its public API, render path, and existing tests are
   unchanged. Presentation-only helpers (labels, CSS/badge classes,
   `schedule_summary`, `duration_label`, `error_preview`) stay in `DashboardView`.

3. **`FaeWeb.StatusContract.build/1`** (new, pure presenter). Takes the same raw
   input map from `Fae.Status.snapshot/0` and produces the machine JSON map
   described below. Derivations go through `Fae.Health` (no drift with the
   dashboard). No CSS, no human labels, no badge classes. Async unit tests.

4. **`FaeWeb.StatusController.show/2`** (new, thin). `Fae.Status.snapshot()` →
   `FaeWeb.StatusContract.build/1` → `json(conn, map)`. No logic.

Router: activate the existing `:api` pipeline (`plug :accepts, ["json"]`) and
add `scope "/api", FaeWeb do pipe_through :api; get "/status", StatusController,
:show end`.

```
quickshell ──HTTP GET /api/status──▶ StatusController.show
                                         │
                          Fae.Status.snapshot/0  (the only reads)
                                         │  raw input map
                                         ▼
                          FaeWeb.StatusContract.build/1  (pure)
                                         │  uses Fae.Health for derivations
                                         ▼
                                    JSON response

DashboardLive.refresh/2 also calls Fae.Status.snapshot/0, then
DashboardView.build/1 (which delegates derivations to Fae.Health).
```

## JSON contract (schema 1)

```json
{
  "schema": 1,
  "generated_at": "2026-05-30T12:34:56Z",
  "health": { "level": "healthy", "reason": null },
  "system": {
    "version": "0.7.0",
    "booted_at": "2026-05-29T08:00:00Z",
    "uptime_seconds": 101696,
    "update": { "state": "idle", "version": null, "published_at": null }
  },
  "backups": {
    "enabled_count": 3,
    "failing_count": 0,
    "next_fire_at": "2026-05-30T18:00:00Z",
    "jobs": [
      {
        "id": "…uuid…",
        "name": "Family Photos",
        "enabled": true,
        "status": "success",
        "last_run_at": "2026-05-30T06:00:00Z",
        "next_fire_at": "2026-05-30T18:00:00Z"
      }
    ]
  },
  "activity": [
    {
      "run_id": "…uuid…",
      "job_name": "Family Photos",
      "status": "success",
      "started_at": "2026-05-30T06:00:00Z",
      "finished_at": "2026-05-30T06:05:12Z",
      "duration_seconds": 312,
      "error": null
    }
  ],
  "dotfiles": {
    "enabled": true,
    "last_backup_at": "2026-05-30T09:12:00Z",
    "last_push_ok": true,
    "tracked_count": 142
  }
}
```

### Field rules

- **All timestamps** are ISO-8601 UTC with a `Z` suffix (`DateTime` → ISO8601).
  Null when unknown. The consumer localizes.
- **`schema`** is an integer. Additive changes (new fields) keep `schema: 1`;
  any breaking change bumps it. Consumers should guard on it.
- **`generated_at`** = `now` from the snapshot (`Clock.now/0`).
- **`health.level`** ∈ `"healthy" | "degraded" | "down"`. `reason` is a short
  human string or `null`.
- **`system.update.state`** ∈ `"idle" | "update_available" | "applying" | "failed"`.
  `version` / `published_at` are populated only when a newer release is cached;
  otherwise `null`.
- **`backups.next_fire_at`** = soonest next fire across enabled jobs, or `null`.
- **`backups.jobs[].status`** = the job's *last run* outcome
  (`"success" | "failed" | "running" | "skipped" | "snoozed"`), or `null` if the
  job has never run. `last_run_at` is that run's `started_at` (or `null`).
  `next_fire_at` is `null` for disabled jobs.
- **`activity[]`** = the most recent runs across all jobs (limit reuses the
  dashboard's `@recent_activity_limit`, 10). `job_name` is `null` if the run's
  job was deleted. `duration_seconds` = `finished_at - started_at` in whole
  seconds, or `null` if the run is still running / has no start. `error` is the
  friendly error summary (text before the first blank line of the stored
  `error_message`), un-truncated, or `null`.
- **`dotfiles`** mirrors the dashboard's dotfiles tile: `enabled`,
  `last_backup_at`, `last_push_ok`, `tracked_count`.

### Deliberately omitted (can be added under schema 1 later)

- Destinations list — not a health signal.
- Per-run progress/percentages.

## Convenience

Add a `just status` recipe that curls the endpoint and pretty-prints it (per
the project's justfile convention). It honors `$PORT` with a 4321 default so it
tracks the install rather than baking in a number:

```
status:
    curl -s "http://127.0.0.1:${PORT:-4321}/api/status" | jq .
```

No endpoint-discovery file is published. External consumers (quickshell, etc.)
hardcode the port the operator assigned to their install — that is the
operator's own config, not a per-install value baked into the Fae repo.

## Payload specification documents (deliverables)

The durable, consumer-facing contract lives outside the process-artifact spec:

- **`docs/api/status.md`** — canonical human-readable payload specification:
  the endpoint, the no-auth/loopback rationale (cross-referencing decision-028),
  the `schema` versioning policy, a field-by-field table (type, nullability,
  meaning, enum values), and a full example response. This is what a person
  reading "how do I consume Fae's status" lands on.
- **`docs/api/status.schema.json`** — a machine-checkable JSON Schema
  (draft 2020-12) describing the response. Authoritative for the payload shape;
  consumers may validate against it. We do **not** add a JSON-Schema validator
  dependency to the app just to validate in tests — `StatusContract` tests
  assert the shape directly (see Testing). The schema is kept in lockstep with
  `FaeWeb.StatusContract` by review.

Both documents must stay in sync with `FaeWeb.StatusContract`; a `schema` bump
or field change updates all three together.

## Testing strategy

- **`Fae.Health`** — async unit tests for each derivation: healthy / degraded
  (1 and >1 failing) / down (self-update failed); `soonest_next_fire` with
  empty and mixed jobs; `classify_update` across idle / available / applying /
  failed. Move the relevant existing `DashboardView` derivation tests here;
  keep delegation tests green.
- **`FaeWeb.StatusContract`** — async unit tests over representative raw input
  maps: all-healthy, a failing job, a never-run job, update-available,
  dotfiles-disabled, a deleted-job activity row, a running run, and the empty
  case (no jobs). Assert exact field shapes, `Z`-suffixed timestamps, and
  `schema: 1`.
- **`FaeWeb.StatusController`** — `ConnCase` test: `GET /api/status` returns 200,
  `content-type: application/json`, decodes to a map with `schema == 1` and the
  documented top-level keys; with a seeded enabled job + run, the job appears in
  `backups.jobs` with the expected `status`.
- **Regression** — full suite stays green and warning-free after the
  `DashboardView` → `Fae.Health` extraction (delegates preserve the API).

## Out of scope

- Authentication / tokens (decision-028 — none needed on loopback).
- SSE / websocket push (polling GET chosen; can be added later as a separate
  endpoint without changing this contract).
- Any write/control actions (run-now, etc.) — this endpoint is read-only.
```
