# Backups tool — manual smoke test

End-to-end checks for the general-purpose Backups tool. Run these after each
significant change to the run pipeline, driver, scheduler, or notifier.

## Prerequisites

- Local Fae running in dev (`iex -S mix phx.server`) or installed
  (`bin/build && bin/install && systemctl --user status fae`).
- A working `notify-send` (libnotify) on PATH for failure notifications.

## A. Local MinIO

```bash
docker run -d -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER=minioadmin \
  -e MINIO_ROOT_PASSWORD=minioadmin \
  --name fae-minio quay.io/minio/minio server /data --console-address ":9001"

# Create a bucket via the console at http://localhost:9001
# or via mc:
mc alias set local http://localhost:9000 minioadmin minioadmin
mc mb local/fae-backups
```

In Fae UI (`http://127.0.0.1:4321/backups/destinations/new`):

- Name: `local-minio`
- Endpoint URL: `http://localhost:9000`
- Region: `us-east-1`
- Bucket: `fae-backups`
- Force path-style: **yes**
- Access key / secret: `minioadmin` / `minioadmin`

Then `/backups/new`:

- Source kind: `sqlite`
- Source path: `/home/<you>/.local/share/fae/fae.db` (or any local SQLite DB)
- Package: `as_is`
- Schedule: `daily 03:00`
- Retention: `keep_last_n` = 3

Click **Run now** twice with a few seconds between. Expect:

1. First run shows `success`; `mc ls local/fae-backups/` lists the new object.
2. Run history shows a row with byte size and sha256.
3. Second consecutive click while the first is still running creates a `skipped` row.

## B. Failure notification

Stop MinIO:

```bash
docker stop fae-minio
```

Click **Run now**. Expect:

- Run row marked `failed` with an error message.
- A critical-urgency desktop notification fires (libnotify).

## C. Retention

Set `keep_last_n` = 2 on a job, then click **Run now** four times spaced a few seconds apart. After the fourth:

```bash
mc ls local/fae-backups/<job-slug>/
```

…should list **two** objects (the two most recent). Older ones have been pruned by the driver's `delete`.

## D. Hetzner

Repeat A against a throwaway Hetzner bucket:

- Endpoint URL: `https://fsn1.your-objectstorage.com`
- Region: `fsn1`
- Force path-style: **yes**

The same success / failure / retention checks should pass.

## E. Restart resilience

```bash
systemctl --user restart fae
# or in dev: Ctrl-C, iex -S mix phx.server
```

After restart, an enabled job's next scheduled run should still fire on time. `Fae.Backups.boot!/0` (invoked from `Fae.Application.post_supervisor_hooks/1`) calls `Scheduler.hydrate/0` which re-inserts the queued Oban worker for every enabled job.
