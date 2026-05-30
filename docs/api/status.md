# Status API — `GET /api/status`

A read-only JSON snapshot of Fae's live operational state, intended for
same-machine consumers (a quickshell bar/dock, shell scripts, etc.).

## Endpoint

```
GET http://127.0.0.1:<port>/api/status
```

`<port>` is the port Fae was started with (`PORT`, default `4321`). Fae binds
`127.0.0.1` only.

### Authentication

None. Fae has no application-layer auth: the endpoint binds loopback only,
which is the entire trust model on a single-user desktop (see
`docs/decisions/architecture/2026-05-16-028-no-application-layer-auth-on-single-user-desktop.md`).
The endpoint is read-only and `GET`-only.

### Discovery

There is no discovery file. A consumer hardcodes the port the operator assigned
to their install (the operator knows their own `PORT`). The bundled
`just status` recipe honors `$PORT` with a `4321` default.

## Versioning

The payload carries an integer `schema` field. **Additive** changes (new
fields) keep the same `schema`; any **breaking** change (removing/renaming a
field, changing a type or meaning) bumps it. Consumers should read `schema`
and degrade gracefully on an unexpected value. The current schema is **1**.

The authoritative machine-readable shape lives in
[`status.schema.json`](status.schema.json) (JSON Schema, draft 2020-12). This
document, that schema, and `FaeWeb.StatusContract` are kept in lockstep.

## Example response

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
        "id": "2f1c…",
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
      "run_id": "9ab3…",
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

## Fields

All timestamps are ISO-8601 UTC, truncated to whole seconds, with a `Z`
suffix; `null` when unknown.

### Top level

| Field          | Type    | Notes |
|----------------|---------|-------|
| `schema`       | integer | Contract version. Currently `1`. |
| `generated_at` | string  | When the snapshot was taken. |
| `health`       | object  | Overall health — your one-glance field. |
| `system`       | object  | Version, uptime, self-update state. |
| `backups`      | object  | Backup aggregates and per-job detail. |
| `activity`     | array   | Most recent runs across all jobs. |
| `dotfiles`     | object  | Dotfiles auto-backup state. |

### `health`

| Field    | Type             | Notes |
|----------|------------------|-------|
| `level`  | string           | `"healthy"` \| `"degraded"` \| `"down"`. |
| `reason` | string \| null   | Short human explanation; `null` when healthy. |

`degraded` means one or more enabled jobs' last run failed. `down` means the
self-update failed.

### `system`

| Field            | Type           | Notes |
|------------------|----------------|-------|
| `version`        | string         | Installed Fae version. |
| `booted_at`      | string         | When this Fae process started. |
| `uptime_seconds` | integer        | Seconds since boot. |
| `update`         | object         | Self-update state (below). |

#### `system.update`

| Field          | Type           | Notes |
|----------------|----------------|-------|
| `state`        | string         | `"idle"` \| `"update_available"` \| `"applying"` \| `"failed"`. |
| `version`      | string \| null | The available release's version; non-null only when `state` is `"update_available"`. |
| `published_at` | string \| null | When that release was published; non-null only when `state` is `"update_available"`. |

### `backups`

| Field           | Type           | Notes |
|-----------------|----------------|-------|
| `enabled_count` | integer        | Number of enabled jobs. |
| `failing_count` | integer        | Enabled jobs whose last run failed. |
| `next_fire_at`  | string \| null | Soonest next fire across enabled jobs; `null` if none. |
| `jobs`          | array          | One row per configured job (enabled or not). |

#### `backups.jobs[]`

| Field          | Type           | Notes |
|----------------|----------------|-------|
| `id`           | string         | Job id (UUID). |
| `name`         | string         | Job name. |
| `enabled`      | boolean        | Whether the job is enabled. |
| `status`       | string \| null | Last run outcome: `"success"` \| `"failed"` \| `"running"` \| `"skipped"` \| `"snoozed"`; `null` if never run. |
| `last_run_at`  | string \| null | Start time of the last run; `null` if never run. |
| `next_fire_at` | string \| null | Next scheduled fire; `null` if the job is disabled. |

### `activity[]`

| Field              | Type            | Notes |
|--------------------|-----------------|-------|
| `run_id`           | string          | Run id (UUID). |
| `job_name`         | string \| null  | Owning job's name; `null` if the job was deleted. |
| `status`           | string          | Run outcome (same values as `backups.jobs[].status`). |
| `started_at`       | string \| null  | When the run started. |
| `finished_at`      | string \| null  | When the run finished; `null` if still running. |
| `duration_seconds` | integer \| null | Whole seconds; `null` if still running or never started. |
| `error`            | string \| null  | Friendly error summary; `null` on success. |

### `dotfiles`

| Field            | Type           | Notes |
|------------------|----------------|-------|
| `enabled`        | boolean        | Whether dotfiles auto-backup is on. |
| `last_backup_at` | string \| null | Last successful backup time; `null` if never. |
| `last_push_ok`   | boolean        | Whether the most recent push succeeded. |
| `tracked_count`  | integer        | Number of tracked files. |

## Consuming it

```sh
# Honors $PORT (default 4321); same as `just status`.
curl -s "http://127.0.0.1:${PORT:-4321}/api/status" | jq .

# One-glance health for a status bar:
curl -s "http://127.0.0.1:4321/api/status" | jq -r .health.level
```
