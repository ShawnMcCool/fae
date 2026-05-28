# Quick Archive

## Problem Statement

Existing Archive (`Fae.Archive`, ADR-030) requires creating a persistent named Run with identity fields (name/label/source/destination) and supports sync/reconfigure semantics — the right shape for curated, content-dated collections. There is no fast path for the common case of "dump this folder into the bucket today, label it 'My Camera Backup', and forget."

Quick Archive fills that gap by piggybacking on the existing verified-archival pipeline with a different key shape and a slimmer form. See [adrs/2026-05-27-031-quick-archive-upload-dated-run-kind.md](../docs/decisions/architecture/2026-05-27-031-quick-archive-upload-dated-run-kind.md) for the architectural rationale.

## User-Facing Behavior

- On `/archive`, a **"Quick Archive"** button sits next to "New Archive".
- The Quick Archive form has three fields:
  - **Destination** (select from existing destinations)
  - **Source** (local file or folder, picker)
  - **Label** (free text, e.g. "My Camera Backup")
- Submitting starts an Oban run immediately. The form previews the computed key path before submission ("This will create: `Family Backups (IMPORTANT)/archive/2026/2026-05-27-my-camera-backup/`") so the operator can sanity-check the slug.
- Files upload to `<destination.path_prefix>/[<destination.quick_archive_prefix>/]<YYYY>/<YYYY-MM-DD>-<slug>/<relative paths>` using the same per-part MD5 + recorded SHA256 + size verification as standard archives. Live progress flows over the existing PubSub topic.
- The Destination form gains a new optional **"Quick Archive subfolder"** field (label may be different; spec below). Defaults blank. Whitespace-trimmed; leading/trailing `/` rejected.
- The runs index lists quick runs alongside standard runs with a small "quick" badge.
- The Show page for a quick run shows **Retry**, **Rename**, **Delete**; hides **Sync** and **Reconfigure**.
- Submitting a Quick Archive with the same label on the same day to the same destination is rejected with a clear error that names and links to the existing run.

## Design

### Data Model Changes

- **Migration**: add `kind` (string, not null, default `"standard"`) to `archive_runs`.
- **Migration**: add `quick_archive_prefix` (string, nullable) to `backup_destinations`.
- **`Fae.Archive.Run`**:
  - Cast `kind` in changesets; default `"standard"` for the existing form path.
  - New `quick_changeset/2` that:
    - Sets `kind: "quick"`.
    - Accepts `name` (the label text the operator typed), `source_path`, `destination_id`, and the precomputed `label`.
    - Validates required + source directory (reuses the existing private validator).
    - Stays Repo-free — slug/label computation and the collision query live in the context (`start_quick_archive/1`), per ADR-019.
- **`Fae.Storage.Destination`**:
  - Cast `quick_archive_prefix`; whitespace-trim; reject leading/trailing `/`; allow nested segments (e.g. `archive/2026-dumps` is valid).

### Behavior Changes

- **`Fae.Archive.KeyBuilder.slugify/1`** — new pure function. NFD normalize via `:unicode.characters_to_nfd_binary/1` → strip combining marks → ASCII filter → lowercase → replace `[^a-z0-9]+` with `-` → trim `-` → return `{:ok, slug}` or `{:error, :empty_slug}` when nothing usable remains.
- **`Fae.Archive.KeyBuilder.quick_label/3`** — new pure function. `(quick_archive_prefix, %Date{}, label_text) :: {:ok, String.t()} | {:error, :empty_slug}`. Composes the stored `label`: `<prefix>/<YYYY>/<YYYY-MM-DD>-<slug>`, omitting an empty/nil prefix. This is the *only* new key-construction code.
- **`Fae.Archive.KeyBuilder.build/3`** — **unchanged.** A quick run stores its dated folder path in `label`, so the worker's existing `build(destination.path_prefix, run.label, relative)` produces the right key with no branch.
- **`Fae.Archive.start_quick_archive/1`** (context entry point, mirrors `start_archive/1`):
  - Loads the destination to read `quick_archive_prefix`.
  - Computes the label via `quick_label/3` against `Date.utc_today()` — the date is frozen here, at click time, not at upload time.
  - Empty-slug → `{:error, %Ecto.Changeset{}}` with an error on `:name`.
  - Collision check — because the date is baked into the label, this is just `from r in Run, where: r.kind == "quick" and r.destination_id == ^dest_id and r.label == ^label`. No date arithmetic needed. On hit, `{:error, :collision, existing_run}`.
  - Otherwise insert with `Run.quick_changeset/2` (sets `kind: "quick"`, `name` = label text, `label` = computed path) and enqueue the existing `ArchiveWorker` — same queue, same worker, same per-item rows.
- Existing **Scanner**, **ArchiveWorker**, **ProgressServer**, **Items** are unchanged.

### LiveView Changes

- **New** `FaeWeb.ArchiveLive.QuickForm` at `/archive/quick/new`.
  - Three fields plus a live path preview.
  - Source picker reuses the existing local picker component.
  - On `{:error, :collision, existing_run}`, render an inline error with a link to the existing run.
- **`FaeWeb.ArchiveLive.Index`**:
  - Add "Quick Archive" button.
  - Render a "quick" badge for `kind: "quick"` rows.
- **`FaeWeb.ArchiveLive.Show`**:
  - Conditionally render Sync and Reconfigure only when `kind: "standard"`.
- **`FaeWeb.DestinationsLive.Form`**:
  - Add the "Quick Archive subfolder" field (label text TBD during implementation — should clearly indicate it's optional and only applies to Quick Archive runs).
- **Router**: `live "/archive/quick/new", ArchiveLive.QuickForm, :new`.

### Integration Points

- **Phoenix.PubSub** — reuses the existing Archive ProgressServer topic. No new topics.
- **Oban** — uses the existing `archive` queue and `ArchiveWorker`. No new queue.
- **Specs** — none (Fae has no public specifications).

### Constraints

- **ADR-027** (desktop with realtime web UI) — UI is LiveView + PubSub; QuickForm follows the pattern.
- **ADR-030** (Archive tool, verified archival move) — verification model, `Fae.Storage` extraction, sub-supervisor tree all reused. The date-imposition reversal for `:quick` is documented in ADR-031.
- **ADR-006** (bounded contexts) — `Fae.Storage.Destination` owns `quick_archive_prefix`; `Fae.Archive.KeyBuilder` is the only consumer.
- **ADR-015** (LiveViews real-time) — quick run progress flows over the existing PubSub topic; QuickForm subscribes on mount.
- **ADR-019** (LiveView logic extraction) — `slugify/1`, key building, collision check are pure or context-level functions; LiveView is glue only.
- **ADR-005** (no magic numbers) — year/date format strings and the slug regex are named module attributes.
- **ADR-002** (code quality standards) — tests first, append-only, no warnings.

## Acceptance Criteria

- [ ] `kind` and `quick_archive_prefix` migrations apply cleanly on a live DB.
- [ ] `KeyBuilder.slugify/1` round-trip tests cover: plain ASCII, Unicode diacritics (é → e, ü → u), mixed case, leading/trailing punctuation, internal punctuation runs, all-punctuation input (rejected).
- [ ] `KeyBuilder.build/3` for `:quick` produces the documented path with and without `quick_archive_prefix`.
- [ ] `Archive.create_quick_run/1` rejects same-day + same-label + same-destination with a structured `{:error, :collision, run}` result.
- [ ] `Archive.create_quick_run/1` allows same label on a different day, or same day on a different destination.
- [ ] `Destination` changeset rejects `quick_archive_prefix` with leading or trailing `/` and accepts nested segments.
- [ ] LiveView smoke test: pick destination, pick source, type label, submit → run created with `kind: "quick"`, scanner enumerates items, redirect to Show.
- [ ] LiveView smoke test: Quick Show page renders Retry and Rename, omits Sync and Reconfigure.
- [ ] LiveView smoke test: Destination form persists `quick_archive_prefix`.
- [ ] LiveView smoke test: same-day same-label collision renders the structured error with a link to the existing run.
- [ ] Existing archive tests (currently 364) continue to pass.

## Decisions

See `docs/decisions/architecture/2026-05-27-031-quick-archive-upload-dated-run-kind.md`.

## Smoke Tests

- **Hermetic**:
  - `KeyBuilder.slugify/1` — unit tests covering the cases listed in acceptance criteria.
  - `KeyBuilder.build/3` `:quick` branch — with and without destination prefix.
  - `Archive.create_quick_run/1` — collision detection, slug stamping, kind defaulting.
  - `Destination` changeset — `quick_archive_prefix` validation.
- **LiveView** (`Phoenix.LiveViewTest`):
  - QuickForm submit happy path.
  - QuickForm collision error rendering.
  - Show page conditional action rendering.
  - Destination form persistence.
- **Integration** (`:integration` tag, MinIO):
  - One end-to-end Quick Archive upload to confirm the dated key shape survives URL-encoding + SigV4 signing. Adds one test to the existing 4 integration tests.

## Implementation Order

1. Migration + schema changes (`kind`, `quick_archive_prefix`).
2. `KeyBuilder.slugify/1` + `:quick` branch with unit tests.
3. `Archive.create_quick_run/1` + collision check with context tests.
4. Destination form field + smoke test.
5. `QuickForm` LiveView + router + smoke tests.
6. Index badge + Show conditional actions + smoke tests.
7. MinIO integration test.
8. Manual end-to-end against the live install with a small test folder.
