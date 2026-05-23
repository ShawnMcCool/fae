---
status: accepted
date: 2026-05-23
---
# Archive tool: verified archival move, distinct from Backups

## Context and Problem Statement

Family photo/video/document collections need to get *into* S3-compatible object storage (Hetzner today, but the driver is provider-agnostic). The collections are large enough that keeping a local mirror is precisely the cost being avoided — so a "sync" tool is wrong by definition, since sync's defining feature is a maintained local copy.

The existing Backups tool ([[027-desktop-application-with-realtime-web-ui]]) is a scheduled, recurring, source-stays-put, one-object-per-run, rotating-retention copier that uploads small files in memory (`Drivers.S3.put/3` does `File.read!/1` then a single PUT). None of that shape fits bulk media ingestion: the files are multi-gigabyte, the run touches thousands of them, and the point is to *move* the pile, not keep copying it on a timer.

The need is a one-shot **archival move**: push a local directory tree up, verify it landed intact, and let the operator reclaim local space by hand later. Object storage becomes the primary — often the only — copy, so the upload must be trustworthy enough to delete the originals on.

Three questions had to be answered:

1. Extend Backups, or build a new tool?
2. Where do the destination/credentials/driver live, now that two tools need them?
3. How is an upload verified strongly enough to trust deletion — across arbitrary S3-compatible providers and arbitrarily large files?

## Decision Outcome

Chosen option: **build a separate `Fae.Archive` tool that performs a verified archival move — scan a local path, stream every file up with transit + recorded integrity checks, record per-file results, and never delete automatically. Extract the destination/credentials/driver into a shared `Fae.Storage` context used by both tools. Verify with per-part `Content-MD5` (the provider rejects corrupted bytes in transit) plus a locally-computed SHA256 stored as the durable record plus a post-upload size check.**

### A separate tool, not an extension of Backups

Archive is the opposite of Backups on every axis: move vs. copy, one-shot vs. scheduled, many-files-per-run vs. one-object, streaming multipart vs. in-memory PUT, no retention vs. rotating retention. Per [[027-desktop-application-with-realtime-web-ui]], tools are sub-supervisor trees; Archive is its own subtree (`Fae.Archive.ProgressServer` under `Fae.Archive.Supervisor`, execution in an Oban `archive` queue via `ArchiveWorker`). Folding this into Backups would have meant a conditional on every one of those axes.

### Archival move, not backup (no auto-delete in v1)

The operator deletes locals manually; Fae's job is to make the copy trustworthy enough that they can. Because object storage becomes the primary store, the verification bar is higher than for a redundant backup. The source must be a **local filesystem path** Fae can read (a folder, a mounted drive, a mounted share) — consolidating phone/laptop data onto such a path is out of scope, which keeps the loopback-only trust model of [[028-no-application-layer-auth-on-single-user-desktop]] intact: no network-facing receiver is introduced.

### A shared `Fae.Storage` context

Destinations, credentials, and the S3 driver were owned by Backups; both tools now need them. Per [[006-bounded-contexts-and-state-ownership]], a storage destination is a storage concern, not a backup concern. They were extracted into `Fae.Storage` (a shared kernel both tools depend on) rather than duplicating credential entry or pointing Archive at Backups' internals (the wrong dependency direction). The table kept its historical name `backup_destinations` to avoid migrating the operator's live data.

### The verification model

Per-part `Content-MD5` is used because it is the lowest common denominator across S3-compatible providers (Hetzner/Ceph RGW, AWS, Backblaze B2, MinIO, …): the provider validates each part on receipt and rejects corruption in transit, without depending on the newer `x-amz-checksum-*` trailers whose support varies by provider. A whole-file SHA256 is folded while streaming and stored on the item row as the durable integrity record the operator can check against the local file before deleting it. A post-upload HEAD confirms the stored byte size. This mirrors the "verify before you trust" posture of [[029-self-update-via-public-github-releases]], applied to upload integrity rather than download authenticity. Files stream in bounded parts (single PUT at or below the part size, S3 multipart above it) so peak memory stays flat regardless of file size — unlike Backups' in-memory PUT.

Implementing this surfaced and fixed a latent SigV4 bug: the signer was double-encoding keys (and form-encoding query params), which the Backups driver shared but never triggered because its keys are slugs/timestamps. Archive's keys carry the operator's real layout — `Family Backups (IMPORTANT)/Pictures Videos/…` — with spaces and parentheses, so the fix (`uri_encode_path: false` plus RFC-3986 query encoding) is now exercised end to end.

### Bucket layout

Keys mirror the source tree as `<destination.path_prefix>/<label>/<relative path>`, with no timestamps. The operator's curation already lives in folder names (year / `YYYY-MM-DD description` / files); Fae preserves that structure rather than imposing a taxonomy of its own.

### What's deferred (YAGNI)

Auto-delete of locals, a cross-run dedup index, recurrence/scheduling/folder-watching, bucket redundancy, a restore/download UI (stable mirrored keys mean restore works today via the provider console or rclone), and receiving data from devices over the network (which would require reopening [[028-no-application-layer-auth-on-single-user-desktop]]). v1 is one-shot bulk archival; "highly configurable" is an explicit later.

### Reversal triggers

- If the operator wants Fae to free local space automatically, revisit auto-delete — and pair it with a stronger gate (e.g. optional re-download-and-rehash).
- If a second independent copy is wanted, revisit bucket redundancy (multi-destination fan-out).
- If recurring ingestion of an evolving tree becomes normal, revisit a persistent dedup index and scheduled runs.
- If devices need to push directly into Fae, that requires reopening [[028-no-application-layer-auth-on-single-user-desktop]].

## Consequences

* Good, because the two tools stay shape-true: Backups remains a small-file scheduled copier, Archive a large-file one-shot mover; neither carries the other's conditionals.
* Good, because `Fae.Storage` gives one place to manage destinations/credentials and one driver to extend — future tools reuse it instead of re-entering credentials.
* Good, because verification is provider-agnostic (`Content-MD5` + recorded SHA256 + size check), proven against MinIO as a neutral S3 reference rather than coupled to Hetzner quirks.
* Good, because streaming keeps memory flat — terabyte collections and multi-GB videos upload without loading files into RAM.
* Good, because resume is DB-driven (skip already-`uploaded` items) and idempotent, surviving restarts and partial failures without re-uploading completed files.
* Bad, because object storage is the primary (often sole) copy until bucket redundancy lands — a lost bucket is lost data, and v1 leans on the operator to remember that.
* Bad, because "no auto-delete" means reclaiming space is a manual step; the tool makes the copy trustworthy but doesn't yet close the loop.
* Bad, because keeping the table named `backup_destinations` under a `Fae.Storage.Destination` schema is a cosmetic wart (documented in the moduledoc) traded for avoiding a data migration on the live install.
* Neutral, because the per-file `archive_items` rows grow with collection size — fine at single-user desktop scale, with paginated detail views deferred.
