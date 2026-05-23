# Reusable Path Browser — Design

**Date:** 2026-05-23
**Status:** Approved (brainstorm)

## Problem

The folder pickers built for the Archive form (local source folder, remote
destination folder) work, but their UI state machine is baked into
`FaeWeb.ArchiveLive.Form`: open/navigate/up/select/close events, the
`start_async` loading, and the modal markup all live inline. Reusing them
anywhere else means copy-pasting ~100 lines of LiveView plumbing.

We want a reusable path browser so any LiveView can drop one in. The first
new caller: from a backup job's detail page, click a button to **browse the
job's backups on the remote destination** (view-only).

## Requirements (decided during brainstorm)

- **Reusable component** — extract a proper component now and wire it into
  both the Archive form and the Backups job view.
- **Two modes:**
  - `:pick` — choose a folder, return its path to a form field (Archive form).
  - `:view` — read-only browse, no selection (Backups job view).
- **Per-use file visibility** — the component supports folder-only listing
  (the form pickers) and folders+files listing (the jobs browser); each
  caller chooses via `show_files`.
- **File detail** in view mode: name + human-readable size + last-modified
  date.
- **Backups browser start location:** the folder holding that job's backups.
  Backup keys are `<destination.path_prefix>/<job.prefix>/<job.slug>/<ts>.<ext>`
  and the remote browser navigates *relative to* `path_prefix`, so the start
  rel is `[job.prefix, job.slug] |> reject(empty) |> join("/")`.

## Approach

Stateful `Phoenix.LiveComponent` plus a shared, pure backend module.
(Phoenix LiveView is 1.1.30, so `start_async`/`handle_async` work inside a
LiveComponent.) Rejected alternatives: a function-component + per-caller
helpers (weak reuse — every caller re-implements the handlers), and a full
source *behaviour* (premature for two sources sharing one driver path; the
component can evolve to that when a third source appears).

## Module layout

Three pieces replace today's `ArchiveLive.Picker` + inline modal:

- **`FaeWeb.PathBrowser`** (`lib/fae_web/components/path_browser.ex`) — the
  stateful `Phoenix.LiveComponent`. Owns the modal markup, navigation state
  (`loc`, `folders`, `files`, `loading`, `error`), `start_async` loading,
  and the `navigate`/`up`/`select`/`close` events. The state machine lives
  only here.

- **`FaeWeb.PathBrowser.Source`** (`lib/fae_web/components/path_browser/source.ex`)
  — pure, source-agnostic backend (promoted from `ArchiveLive.Picker`).
  `list(source, show_files?)` returns
  `{:ok, %{folders: [name], files: [%{name, size, last_modified}]}}`, plus
  path math `down/3`, `up/1`, `location_label/1`. `:local` uses `File`;
  `:remote` delegates to the storage driver. Remote leaf-naming is split
  into a pure `relativize/2` helper so it tests without network.

- **`Fae.Storage.Drivers.Driver` + `S3`** — `list_prefixes/2` enriched to
  return files **with metadata**: `%{prefixes: [...], files: [%{key, size,
  last_modified}]}`. The Archive picker only reads `prefixes`, so it is
  unaffected.

The old `FaeWeb.ArchiveLive.Picker` module is deleted; its logic moves into
`Source`.

## Component interface

Parent renders the component only when a browse is open:

```elixir
<.live_component
  :if={@browser}
  module={FaeWeb.PathBrowser} id="path-browser"
  source={@browser.source}        # {:local, start_path} | {:remote, %Destination{}, start_rel}
  mode={@browser.mode}            # :pick | :view
  show_files={@browser.show_files}
  title={@browser.title}
  return_to={@browser.return_to}  # opaque tag echoed back on select (e.g. :source_path)
/>
```

The component sends exactly two messages back to the parent process (it
shares the parent's process, so plain `send(self(), …)` → `handle_info`):

- `{:path_browser, :selected, return_to, value}` — only in `:pick` mode;
  `value` is the chosen local path or remote rel.
- `{:path_browser, :closed}` — cancel / backdrop / close.

Each parent therefore writes only: an open-handler that sets `@browser`, a
`handle_info(:selected…)`, and a `handle_info(:closed…)`. In `:view` mode
there is no "Use this folder" button and `return_to` is ignored.

## Data flow

1. **Open → load.** Parent button sets `@browser` to a spec map; the
   component renders. `update/2` runs once (guarded by an `initialized?`
   flag so later parent re-renders don't reset navigation): seeds `loc` from
   the source's start location and fires `start_async(:load, …)`.
   `handle_async` fills `folders`/`files`, clears `loading`.
2. **Navigate.** Clicking a folder → `navigate` sets `loc = Source.down(…)`
   and reloads. `up` does `loc = Source.up(loc)` and reloads. Files are
   inert rows (view-only), not navigation targets.
3. **Finish.** `:pick` mode "Use this folder" sends `:selected`; the parent
   writes the value and clears `@browser`. Close/backdrop sends `:closed`;
   the parent clears `@browser`.

Navigation state lives entirely in the component and is discarded when
`@browser` clears — reopening starts fresh from the source's start location.

## Backend & driver changes

- **`S3.parse_prefixes/1`** already scans `<Contents>`; extend it to also
  pull `<Size>` and `<LastModified>`, returning `files: [%{key, size,
  last_modified}]` instead of bare `keys`. Update the `Driver` behaviour's
  `list_prefixes` callback type and the `DriverMock` to match. (The
  recursive `list/2` already parses size/last_modified — same logic reused.)
- **`Source.list/2`:**
  - `{:local, path}` → `File.ls` then partition into dirs and files; for
    files, `File.stat!` gives `size` and `mtime` (→ `last_modified`). When
    `show_files?` is false, skip the file work.
  - `{:remote, dest, rel}` → build the s3 prefix (`path_prefix` + rel), call
    `driver.list_prefixes`, then pure `relativize/2` turns full
    prefixes/keys into leaf names carrying metadata.
- **Sorting:** folders alpha, then files alpha (matches today's folder sort).

## Wiring the callers

**Archive form** (`ArchiveLive.Form`): delete the inline picker state, the
five `picker_*` events, the four `handle_async(:picker_load…)` clauses, and
the modal markup. Replace with: `assign(:browser, nil)` in mount; the two
open-buttons set `@browser` (`{:local, local_start}` / `{:remote, dest, ""}`,
both `mode: :pick`, `show_files: false`, `return_to: :source_path | :label`);
render `<.live_component>`; add two `handle_info` clauses — `:selected`
reuses the existing `put_field/3`, `:closed` clears. Behavior is identical to
today.

**Backups job show** (`BackupsLive.JobShow`): add a "Browse backups" button
(disabled with a hint if `@job.destination` is nil). It sets `@browser` to
`{:remote, job.destination, start_rel}` with `start_rel = [job.prefix,
job.slug] |> reject(empty) |> join("/")`, `mode: :view`, `show_files: true`,
`title: "Backups in #{job.name}"`. Render `<.live_component>` and a
`:closed` handler. No `:selected` handler (view-only).

## Error handling

Async `{:error, reason}` / `{:exit, reason}` set `error` (inspected) and
clear `loading`, shown in the modal — same as today. Local `File.ls` errors
(e.g. permission denied) surface the same way. Remote auth/network errors
arrive from the driver as `{:error, …}`.

## Testing

- **`Source` unit tests** (async): `list/2` local on a `tmp_dir` (folders +
  files with size/mtime; `show_files: false` hides files), `down`/`up`/
  `location_label`, and `relativize/2` remote leaf-naming + metadata.
- **`S3.parse_prefixes/1` test:** XML with `Contents` Size/LastModified
  parses into `files`.
- **Integration** (LiveViewTest): Archive form — open local picker,
  navigate, select writes the field (real FS); open remote picker via
  `DriverMock`. Backups job show — open view-only browser via `DriverMock`,
  assert files render with size/date and no "Use this" button.

## Out of scope

- Acting on files (download / delete / restore) from the browser — view-only
  for now.
- A formal source behaviour / additional source backends (FTP, other
  clouds) — revisit when a third source appears.
