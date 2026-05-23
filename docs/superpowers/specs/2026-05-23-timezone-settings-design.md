# Timezone settings + site-wide localized dates — design

**Date:** 2026-05-23
**Status:** approved (brainstorming)

## Problem

Every date/time on the site is currently rendered to UTC by ad-hoc private
functions (`format_dt`, `format_date`, `format_at`) scattered across ~6
LiveViews, each calling `Calendar.strftime(dt, "… UTC")` directly. There is no
way for the user to see times in their own timezone, and nothing prevents a new
page from rendering yet another raw UTC string.

Two goals:

1. A **settings page** where the user picks their timezone conveniently.
2. A **guard-rail** so that *every* date/time on the site renders in the
   selected timezone — and it is structurally hard to bypass.

## Context

- Single-user desktop app, Phoenix LiveView, bound to loopback only. No auth,
  no scopes.
- `Fae.Settings` already exists: a key/value store backed by one SQLite table,
  values are arbitrary maps, writes broadcast `{:setting_changed, key, value}`
  on the `Phoenix.PubSub` topic `"settings"`. Reads go straight to the Repo (no
  cache by design — local SQLite reads are cheap).
- `tzdata` is a dependency and configured as `:time_zone_database`, so
  `DateTime.shift_zone!/2` works for any IANA zone.
- Phoenix 1.8 **colocated hooks** are wired (`phoenix-colocated/fae`), so a JS
  hook can live next to the component that uses it.
- `core_components` provides `<.input type="select">` (with `options`/`prompt`)
  and `<.button>` for reuse.
- Every LiveView in the `:default` `live_session` already runs
  `on_mount: [FaeWeb.SidebarScope]`.

## Architectural decision: how the date component gets the zone

**Chosen — approach A: an `on_mount` hook assigns `@timezone` to every
LiveView.** A hook reads the timezone once at mount, assigns `@timezone`,
subscribes to the existing `"settings"` topic, and re-assigns when it changes —
so every open page re-renders instantly (per the "LiveViews must be realtime"
decision). The date component takes `tz` as a **required** attribute, so a date
cannot be rendered without a zone.

Rejected — approach B: a `:persistent_term` global cache read by the component.
Live pages still need an assign change to re-render, so the subscription is
required anyway; B adds a cache without removing work, and `Fae.Settings`
deliberately avoids caching.

## Design

### 1. `Fae.Display` — domain context, single source of truth for the zone

Thin typed wrapper over `Fae.Settings`. Key `"display"`, value
`%{"timezone" => "Europe/Amsterdam"}`.

- `timezone/0` → stored zone, or `"UTC"` default.
- `put_timezone/1` → validates against `Tzdata.zone_list/0`, writes via
  `Fae.Settings.put("display", %{"timezone" => name})` (which broadcasts the
  change). Returns `{:ok, name}` or `{:error, :invalid_timezone}`.
- `valid_timezone?/1` → membership in `Tzdata.zone_list/0`.
- `zone_options/0` → sorted zone names for the `<select>`.

### 2. `FaeWeb.TimeDisplay` — the chokepoint (only place dates are formatted)

Pure functions, async unit tests (per the LiveView-logic-extraction decision):

- `format(utc_datetime, tz, fmt)` where `fmt ∈ :date | :datetime |
  :datetime_seconds | :time`. Shifts UTC → tz with `DateTime.shift_zone!/2`,
  formats with `Calendar.strftime`, appends the zone abbreviation (`CEST`,
  `UTC`) so the value is unambiguous. `nil → "—"`. Defensive fallback to a UTC
  render if `shift_zone` somehow fails (should not happen with validated zones).

Function components:

- `<.local_datetime value={dt} tz={@timezone} format={:datetime} />` — renders
  the text plus a `title` tooltip carrying the fuller local timestamp.
- `<.relative_time value={dt} tz={@timezone} />` — "3 min ago", with the
  absolute local time in the tooltip.

`tz` is a **required** attr on both. This module is the *only* place under
`lib/fae_web` permitted to call `Calendar.strftime` / `DateTime.to_iso8601` /
naive date formatting (enforced by Credo, see §5).

### 3. `FaeWeb.DisplayScope` — `on_mount` hook

Router becomes `on_mount: [FaeWeb.SidebarScope, FaeWeb.DisplayScope]`.

- Assigns `@timezone = Fae.Display.timezone()`.
- When `connected?(socket)`: `Fae.Settings.subscribe()` and
  `attach_hook(:display_tz, :handle_info, …)` to re-assign `@timezone` on
  `{:setting_changed, "display", value}` → automatic re-render of every open
  page.

Kept separate from `SidebarScope` (whose moduledoc states it holds no persisted
state). The single cheap SQLite read per mount is acceptable; `Fae.Settings` is
designed for direct reads. Subscription only happens on the connected mount, so
the static render does not subscribe.

### 4. `FaeWeb.SettingsLive` — the settings page at `/settings`

- `mount/3`: setup only (no DB queries).
- `handle_params/3`: load current timezone + zone options.
- Colocated JS hook `TimezoneDetect`: on connect, pushes
  `Intl.DateTimeFormat().resolvedOptions().timeZone` → assigns
  `@detected_timezone` → renders a one-click **"Use detected: Europe/Amsterdam"**
  button. If the detected zone is unknown to tzdata, no button.
- A searchable manual `<.input type="select">` override; shows "Current: …".
- `handle_event` for "use_detected" and manual "save" → `Fae.Display.put_timezone/1`.
  The resulting broadcast updates the whole site live (including this page, via
  `DisplayScope`).
- Sidebar nav gains `%{path: "/settings", label: "Settings",
  icon: "hero-cog-6-tooth"}` (its own group near the bottom).

### 5. Custom Credo check — enforcement

- Add `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}`.
- A focused `.credo.exs` that runs essentially **just our custom check** — not
  Credo's full default ruleset (which would dump pre-existing findings into the
  gate). Adopting the broader ruleset can be a later, separate decision.
- `Fae.Credo.Check.UnlocalizedDateTime`: flags `Calendar.strftime`,
  `DateTime.to_iso8601`, and naive date formatting anywhere under `lib/fae_web`
  **except** `FaeWeb.TimeDisplay`.
- Wire `credo` into the `precommit` mix alias (which `just check` already runs).

### 6. Refactor the existing render sites → `<.local_datetime>`

Replace private formatters with the component, passing `@timezone`:

- `lib/fae_web/components/path_browser.ex` (LiveComponent — parent passes `tz`)
- `lib/fae_web/live/backups_live/index.ex`
- `lib/fae_web/live/backups_live/job_show.ex`
- `lib/fae_web/live/update_live.ex` (incl. the `title` ISO tooltip → local)
- `lib/fae_web/live/archive_live/index.ex`
- `lib/fae_web/live/dashboard_live.ex` (incl. `@system.boot_at`)

Their `format_dt`/`format_date`/`format_at` private functions are deleted.

### 7. Out of scope

- Domain-layer dates that are **not** "on the site" stay UTC: backup filenames,
  retention math, schedules, S3 object keys. The Credo check is scoped to
  `lib/fae_web` only.
- Per YAGNI: 12/24-hour and date-format preferences. The formatter is
  structured so these drop in later without touching call sites.

## Error handling

- Invalid/unknown zone on save → `{:error, :invalid_timezone}`, surface a flash,
  keep current zone.
- Detected zone not in tzdata → no "use detected" button.
- `nil` datetime → "—".
- `shift_zone` failure → defensive fallback to UTC render.

## Testing

- `Fae.Display`: default is UTC; put/get round-trip; validation rejects bad
  zones; a change broadcasts `{:setting_changed, "display", …}`.
- `FaeWeb.TimeDisplay` (async, pure): UTC→tz shift including a DST pair
  (summer CEST vs winter CET); each format variant; `nil` handling; zone
  abbreviation present.
- `FaeWeb.SettingsLive` + `DisplayScope` (LiveView tests): page shows current
  zone; saving changes it; a second mounted view updates live via PubSub; the
  detected-zone button works.
- The Credo check itself: flags a violating source, passes clean source.
- Existing LiveView date tests: default tz is UTC in test env, so " UTC"
  output is preserved — minimal churn.

## Migration note

The working tree has uncommitted changes to `backups_live/index.ex`,
`job_show.ex`, and two test files (three of which §6 refactors). Commit or stash
that WIP first so this work lands cleanly.
