# Backup source picker — design

**Date:** 2026-05-30
**Status:** Approved, ready for planning

## Problem

The backup job form (`FaeWeb.BackupsLive.JobForm`) takes the thing to back up
as a free-text `source_path` field. The operator must know and type the exact
path. The archive forms already solved this with a reusable `PathBrowser`
modal and a Browse button, but the backup form was never wired up to it.

Backups differ from archives in one way that matters: a backup job's
`source_kind` is one of `file`, `folder`, or `sqlite`. Folders map cleanly to
the existing picker, but `file` and `sqlite` need to select an **individual
file** — and the current `PathBrowser`, even with `show_files: true`, only
returns the *current folder* ("Use this folder"); files are display-only.

## Goal

Add a context-aware Browse button to the backup form's `source_path` field
that opens `PathBrowser`, adapting to the selected `source_kind`:
- `folder` → pick a folder (existing behavior)
- `file` / `sqlite` → pick an individual file

## Non-goals

- No schema change or migration — `source_path` is unchanged.
- No form-time path-existence validation — backups keep their existing
  runtime validation in the source adapters.
- No remote browsing — backup sources are always local.

## Design

### 1. Extend `PathBrowser` to pick a file

`FaeWeb.PathBrowser` gains one optional assign:

```
pick: :folder | :file   # default :folder
```

Default is set with `assign_new(:pick, fn -> :folder end)` so existing callers
(the archive forms) that omit it keep today's behavior unchanged.

- **`pick: :folder`** — footer shows **"Use this folder"**, which sends the
  current location (`{:path_browser, :selected, return_to, loc}`). Files, if
  shown, stay display-only. Unchanged from today.
- **`pick: :file`** — each listed file renders as a clickable button. Clicking
  a file sends `{:path_browser, :selected, return_to, Source.down(kind, loc, name)}`
  — the file's full path. The "Use this folder" footer button is hidden; the
  footer is just **Cancel**.

`pick: :file` requires `show_files: true` (the caller sets both). A new
`handle_event("select_file", %{"name" => name}, socket)` mirrors the existing
`"select"` handler:

```elixir
def handle_event("select_file", %{"name" => name}, socket) do
  value = Source.down(socket.assigns.kind, socket.assigns.loc, name)
  send(self(), {:path_browser, :selected, socket.assigns.return_to, value})
  {:noreply, socket}
end
```

`Source.down(:local, loc, name)` is `Path.join(loc, name)` — exactly the file's
full path. No new `Source` function is needed.

### 2. Wire a context-aware Browse button into the backup form

Next to the `source_path` input, add a `btn-square btn-ghost` Browse button
(same visual pattern as the archive forms — flex row, grow input, square
ghost button with a Heroicon). Clicking it opens `PathBrowser` configured from
the currently-selected `source_kind`:

| `source_kind`     | Picker config                                | Footer            |
|-------------------|----------------------------------------------|-------------------|
| `folder`          | `pick: :folder, show_files: false`, "Choose a folder" | "Use this folder" |
| `file`            | `pick: :file, show_files: true`, "Choose a file"      | click a file      |
| `sqlite`          | `pick: :file, show_files: true`, "Choose a SQLite database" | click a file |
| (unset / unknown) | treated as `file`                            | click a file      |

An unset `source_kind` defaults to file-picking, matching the dropdown's
visually-selected first option ("File").

New plumbing on `JobForm` (mirrors `ArchiveLive.QuickForm`):

- `:browser` assign initialized to `nil` in `mount`.
- `open_source_picker` event builds the browser map from `current_source_kind`
  and `picker_start`, then `assign(socket, :browser, browser)`.
- `handle_info({:path_browser, :selected, return_to, value}, socket)` merges the
  value into the form params under `source_path`, rebuilds the changeset
  (reusing `with_retention_params/1`, action `:validate`), and clears `:browser`.
- `handle_info({:path_browser, :closed}, socket)` clears `:browser`.

The picker's start directory: if `source_path` is already set, start in its
directory (the path itself if it's a dir, otherwise its parent); else `$HOME`.

The `<.live_component module={PathBrowser} …>` is rendered at the end of the
template (conditional on `@browser`), passing `tz={@timezone}` and the new
`pick={@browser.pick}` assign.

### 3. Logic extraction & tests (decision 019)

- Extract the pure mapping `source_kind → picker config` as a public function
  `JobForm.source_picker_config/2` (`source_kind`, `start_path` → browser map),
  with an async unit test covering `folder`, `file`, `sqlite`, and the
  nil/default-to-`file` case. `picker_start` stays a thin impure wrapper
  (`File.dir?`) that feeds `start_path` in.
- `PathBrowser`: test that `pick: :file` makes files selectable and returns the
  joined full path, and that `pick: :folder` is unchanged.
- `JobForm` LiveView test: clicking Browse opens the modal; the modal's
  file/folder mode follows `source_kind`; selecting fills `source_path`.

## Affected files

- `lib/fae_web/components/path_browser.ex` — add `pick` assign, `select_file`
  handler, conditional rendering of selectable files vs. "Use this folder".
- `lib/fae_web/live/backups_live/job_form.ex` — Browse button, `:browser`
  plumbing, `source_picker_config/2`, `picker_start`.
- `test/…` — unit + LiveView tests as above.
