---
status: proposed
date: 2026-05-27
---
# Quick Archive: upload-dated archival as a Run kind on Fae.Archive

## Context and Problem Statement

[[030-archive-tool-verified-archival-move]] established Archive as a curated, content-dated, persistent-config workflow: the operator creates a named Run with a source, label, and destination, and the bucket layout mirrors the on-disk tree because the curation (year folders, `YYYY-MM-DD description` folders) already lives there. Sync, reconfigure, and rename support evolving the config over time.

That shape is wrong for a second, equally common operator intent: *"I want to dump this folder into the bucket today, label it 'My Camera Backup', and forget."* There is no curation to preserve, no long-lived config to evolve, no event date to mirror — the operator's intent is exactly "stamp this with today's date and move on." Forcing this through the existing Archive form (with name/label/source/destination identity fields and an editable Run record afterward) is overkill, and the resulting Run sits in the index pretending to be something that could be synced or reconfigured when neither makes sense for what it is.

Three questions had to be answered:

1. Add this as a second mode of the existing Archive tool, or build a separate `Fae.QuickArchive` tool?
2. How does the dated path get composed, and where does the configurable root live?
3. What does the operator do when they accidentally submit the same label twice on the same day?

## Decision Outcome

Chosen option: **add a `kind` discriminator (`:standard` | `:quick`) to `Fae.Archive.Run`. Quick runs share the supervisor, worker, item-row schema, progress server, verification (per-part MD5 + recorded SHA256 + size HEAD), destination model, scanner, *and the key builder* with standard runs. A quick run composes its dated folder path once at creation time and stores it in the existing `label` field — the field already means "the remote folder segment of the object key, after the destination's path_prefix." So the effective key `<destination.path_prefix>/[<destination.quick_archive_prefix>/]<YYYY>/<YYYY-MM-DD>-<slug>/<relative>` is produced by the unchanged `KeyBuilder.build/3` with a precomputed label. `quick_archive_prefix` is a new nullable column on `backup_destinations` so the operator can keep quick dumps in a sibling folder from curated archives. Same-day same-label collisions to the same destination are rejected with a pointer to the existing run.**

### A second kind on the same tool, not a second tool

Per [[027-desktop-application-with-realtime-web-ui]] tools are sub-supervisor trees. The temptation is to build `Fae.QuickArchive` as a sibling subtree under the root supervisor — symmetric with `Fae.Archive` and `Fae.Backups`. That would double the surface (two supervisors, two workers, two progress servers, two LiveView trees, two doc pages, two sidebar entries) for what is the same verified-archival pipeline with a different key shape. Per [[006-bounded-contexts-and-state-ownership]] the bounded context is *archival upload with integrity verification*, not *the specific key strategy used*. Both kinds belong to `Fae.Archive`; the discriminator lives on the Run.

The operator-facing names ("New Archive" vs "Quick Archive") preserve the mental model of two workflows without imposing the duplication of two tools.

### Upload date, not content date — bounded to `:quick`, computed at creation

ADR-030 deliberately avoided imposing a date taxonomy because the operator's curation already lived in folder names. Quick Archive reverses that *for this kind only* because there is no curated structure to preserve and the operator's stated intent is to stamp the upload with today's date. The reversal is bounded: `:standard` runs continue to mirror the source tree byte-for-byte; only `:quick` runs prepend the `<YYYY>/<YYYY-MM-DD>-<slug>/` segments.

Crucially, the date is resolved **when the operator clicks**, not when the worker uploads. The dated path is composed once in `create_quick_run/1` and frozen in the `label` column, so a run enqueued at 23:59 and executed (or resumed after a restart) the next day still carries the date the operator saw. Computing the date in the worker would risk a key that disagrees with the operator's intent across a midnight boundary.

This also means `KeyBuilder.build/3` does not branch on kind: it still receives `(path_prefix, label, relative)`. The only new key-building code is two pure helpers — `slugify/1` (label → URL-safe segment) and `quick_label/3` (prefix + date + label → the stored `label` string). Two date semantics coexist in the codebase, intentionally and per-kind, but the hot path stays single-shaped.

### Per-destination `quick_archive_prefix`

A new nullable `quick_archive_prefix` column on `backup_destinations`. Configured on the Destination form; the Quick Archive form does not show it. This preserves the "three fields" intent of the quick workflow (destination, source, label) while letting the operator route quick dumps into a sibling folder from curated archives. Concretely, an operator can configure their family destination to drop quick archives under `Family Backups (IMPORTANT)/archive/...` while standard archives keep landing under `Family Backups (IMPORTANT)/Pictures Videos/...`. Operators who don't care leave it blank and quick archives drop straight under `path_prefix`.

The alternative — a Quick Archive form field for per-run override — adds a fourth field to a workflow whose whole point is being short, and a quick run with a custom root isn't really quick anymore (use a standard Archive Run for that). Promoting to a form field is a reversal trigger if it turns out to be needed.

### Slug rules

The slug is computed from the operator-supplied label: NFKD-normalize to strip diacritics, lowercase, replace runs of non-`[a-z0-9]` with `-`, trim leading/trailing `-`, reject empty post-slug. Implemented in `Fae.Archive.KeyBuilder.slugify/1` as a pure function with property-style tests. Rejecting empty post-slug means an operator who types only punctuation gets a clear error rather than a path with an empty segment.

### Same-day same-label collisions: reject

Silent disambiguation (appending `-2` or a HH-MM-SS) hides operator confusion: the operator typed the same label twice on the same day and probably didn't mean to. Reject with a structured error that names the existing run and links to it, so the operator picks a different label or waits a day. If this turns out to be common enough to annoy, switch to time-of-day disambiguation — listed as a reversal trigger.

### Action set on quick runs

The Show page hides **Sync** (re-scan for new files is incoherent — a quick run is a frozen snapshot of what existed at upload time) and **Reconfigure** (the key has today's date baked in; reconfiguring would orphan everything in the bucket). **Rename** stays (it's the friendly name, not the key). **Retry** stays — it resumes the same run by skipping already-uploaded items, which is exactly what you want when an upload dies midway. **Delete** stays.

### Reversal triggers

- If operators routinely want per-run prefix overrides, promote `quick_archive_prefix` to a Quick Archive form field.
- If same-day same-label collisions are common enough to annoy, switch to time-of-day disambiguation (`YYYY-MM-DD-HHMMSS-slug`).
- If the runs index becomes unwieldy with both kinds mixed, split the listing or add a filter.
- If a third date strategy emerges, revisit whether `kind` is the right discriminator or whether key-strategy belongs on its own field.

## Consequences

* Good, because zero duplication of verification, storage, supervision, item tracking, scanner, or progress UI — all reused via the existing Archive pipeline.
* Good, because the operator's quick-archive workflow is three fields and the per-destination prefix is configured once.
* Good, because standard archives' bucket layout is untouched; quick dumps can live in a sibling folder rather than mixing in with curated content.
* Good, because the dated path is precomputed into the existing `label` field, so `KeyBuilder.build/3`, the worker, and the scanner are untouched; the rest of the pipeline doesn't know what kind it is.
* Good, because the date is frozen at creation, so the key the operator saw survives enqueue delays, restarts, and midnight boundaries.
* Bad, because `Fae.Archive.Run` grows a discriminator that the index/listing/detail paths must handle (mostly cosmetic — a badge in the list, hidden actions on Show).
* Bad, because two date semantics (content date for `:standard`, upload date for `:quick`) now coexist in the codebase; future contributors must internalize that the per-kind split is intentional.
* Neutral, because same-day collisions reject — rare in practice but operator-visible when it happens; the reversal trigger is documented if it turns out to be annoying.
