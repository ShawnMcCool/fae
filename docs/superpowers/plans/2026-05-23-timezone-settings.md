# Timezone Settings + Site-Wide Localized Dates — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pick a timezone on a settings page and render every date/time across the web UI in that zone, enforced by a custom Credo check so no page can render a raw UTC value.

**Architecture:** A `Fae.Display` context owns the timezone preference (stored via the existing `Fae.Settings` K/V store, default `"UTC"`). `FaeWeb.TimeDisplay` is the single chokepoint that formats dates (pure `format/3` + `<.local_datetime>` / `<.relative_time>` components). An `on_mount` hook (`FaeWeb.DisplayScope`) assigns `@timezone` to every LiveView and live-updates it via the `"settings"` PubSub topic. A custom Credo check fails the build if any module under `lib/fae_web` (except `TimeDisplay`) calls `Calendar.strftime` or `DateTime.to_iso8601` directly.

**Tech Stack:** Elixir, Phoenix LiveView 1.8 (colocated hooks), Ecto/SQLite, `tzdata` (already configured as `:time_zone_database`), Credo (new dev/test dep).

**Before you start:** The working tree has uncommitted changes to `lib/fae_web/live/backups_live/index.ex`, `job_show.ex`, and two test files (three of which Task 6 touches). Commit or stash that WIP first so this work lands cleanly. Spec: `docs/superpowers/specs/2026-05-23-timezone-settings-design.md`.

**Key fact that simplifies the refactor:** At the default `"UTC"` timezone, `TimeDisplay.format/3` produces byte-identical output to today's hardcoded strings (`%Y-%m-%d %H:%M UTC`, etc.), so existing LiveView tests keep passing without changes. Only `update_live_test.exs` needs editing (the `time_ago` function moves modules in Task 7).

---

### Task 1: `Fae.Display` context (timezone preference)

**Files:**
- Create: `lib/fae/display.ex`
- Test: `test/fae/display_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/fae/display_test.exs
defmodule Fae.DisplayTest do
  # async: false — writes go through Fae.Settings, which shares a PubSub
  # topic and a DB table across the suite.
  use Fae.DataCase, async: false

  alias Fae.Display

  describe "timezone/0" do
    test "defaults to UTC when nothing is stored" do
      assert Display.timezone() == "UTC"
    end

    test "returns the stored timezone after put_timezone/1" do
      {:ok, "Europe/Amsterdam"} = Display.put_timezone("Europe/Amsterdam")
      assert Display.timezone() == "Europe/Amsterdam"
    end
  end

  describe "put_timezone/1" do
    test "rejects an unknown zone and leaves the current value untouched" do
      assert {:error, :invalid_timezone} = Display.put_timezone("Mars/Phobos")
      assert Display.timezone() == "UTC"
    end

    test "broadcasts a settings change on the \"settings\" topic" do
      :ok = Fae.Settings.subscribe()
      {:ok, _} = Display.put_timezone("America/New_York")
      assert_receive {:setting_changed, "display", %{"timezone" => "America/New_York"}}
    end
  end

  describe "valid_timezone?/1" do
    test "accepts UTC and a real IANA zone, rejects junk" do
      assert Display.valid_timezone?("UTC")
      assert Display.valid_timezone?("Europe/Amsterdam")
      refute Display.valid_timezone?("Mars/Phobos")
      refute Display.valid_timezone?(nil)
    end
  end

  describe "zone_options/0" do
    test "is a non-empty list that includes a known zone" do
      options = Display.zone_options()
      assert is_list(options)
      assert "Europe/Amsterdam" in options
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/fae/display_test.exs`
Expected: FAIL — `Fae.Display` is undefined.

- [ ] **Step 3: Write the implementation**

```elixir
# lib/fae/display.ex
defmodule Fae.Display do
  @moduledoc """
  User display preferences. Currently just the timezone that all
  dates/times render in across the web UI.

  Backed by `Fae.Settings` under the `"display"` key; reads default to
  `"UTC"` until the user picks a zone. Writes validate against the IANA
  zone list and broadcast on the `"settings"` PubSub topic, so open
  LiveViews re-render in the new zone immediately (see
  `FaeWeb.DisplayScope`).
  """

  alias Fae.Settings

  @settings_key "display"
  @default_timezone "UTC"

  @doc "The configured timezone, or \"UTC\" if none is set."
  @spec timezone() :: String.t()
  def timezone do
    case Settings.get_by_key(@settings_key) do
      {:ok, %{value: %{"timezone" => tz}}} when is_binary(tz) -> tz
      _ -> @default_timezone
    end
  end

  @doc "Validate and persist a timezone. Broadcasts the change."
  @spec put_timezone(String.t()) :: {:ok, String.t()} | {:error, :invalid_timezone}
  def put_timezone(timezone) when is_binary(timezone) do
    if valid_timezone?(timezone) do
      {:ok, _entry} = Settings.put(@settings_key, %{"timezone" => timezone})
      {:ok, timezone}
    else
      {:error, :invalid_timezone}
    end
  end

  @doc "True when `timezone` is a known IANA zone name."
  @spec valid_timezone?(term()) :: boolean()
  def valid_timezone?(timezone) when is_binary(timezone), do: timezone in zone_list()
  def valid_timezone?(_), do: false

  @doc "Sorted list of IANA zone names for a `<select>`."
  @spec zone_options() :: [String.t()]
  def zone_options, do: zone_list()

  @doc "The default timezone used before the user picks one."
  @spec default_timezone() :: String.t()
  def default_timezone, do: @default_timezone

  defp zone_list, do: Tzdata.zone_list()
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/fae/display_test.exs`
Expected: PASS (all 6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/fae/display.ex test/fae/display_test.exs
git commit -m "Add Fae.Display: timezone preference over Fae.Settings"
```

---

### Task 2: `FaeWeb.TimeDisplay` pure formatting functions

**Files:**
- Create: `lib/fae_web/time_display.ex`
- Test: `test/fae_web/time_display_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/fae_web/time_display_test.exs
defmodule FaeWeb.TimeDisplayTest do
  use ExUnit.Case, async: true

  alias FaeWeb.TimeDisplay

  describe "format/3 at UTC (output-preserving baseline)" do
    @utc ~U[2026-05-23 14:30:45Z]

    test ":datetime matches the legacy '%Y-%m-%d %H:%M UTC' string" do
      assert TimeDisplay.format(@utc, "UTC", :datetime) == "2026-05-23 14:30 UTC"
    end

    test ":datetime_seconds includes seconds" do
      assert TimeDisplay.format(@utc, "UTC", :datetime_seconds) == "2026-05-23 14:30:45 UTC"
    end

    test ":date is zone-free" do
      assert TimeDisplay.format(@utc, "UTC", :date) == "2026-05-23"
    end

    test ":time is HH:MM plus abbreviation" do
      assert TimeDisplay.format(@utc, "UTC", :time) == "14:30 UTC"
    end

    test "nil renders an em dash" do
      assert TimeDisplay.format(nil, "UTC", :datetime) == "—"
    end
  end

  describe "format/3 shifts into the target zone (incl. DST)" do
    test "summer date renders as CEST (UTC+2)" do
      assert TimeDisplay.format(~U[2026-07-01 12:00:00Z], "Europe/Amsterdam", :datetime) ==
               "2026-07-01 14:00 CEST"
    end

    test "winter date renders as CET (UTC+1)" do
      assert TimeDisplay.format(~U[2026-01-01 12:00:00Z], "Europe/Amsterdam", :datetime) ==
               "2026-01-01 13:00 CET"
    end

    test "an unknown zone falls back to a UTC render" do
      assert TimeDisplay.format(~U[2026-05-23 14:30:00Z], "Mars/Phobos", :datetime) ==
               "2026-05-23 14:30 UTC"
    end
  end

  describe "time_ago/2" do
    test "buckets sub-minute, minutes, hours, days; nil passes through" do
      now = ~U[2026-05-23 12:00:00Z]
      assert TimeDisplay.time_ago(nil, now) == nil
      assert TimeDisplay.time_ago(DateTime.add(now, -2, :second), now) == "just now"
      assert TimeDisplay.time_ago(DateTime.add(now, -30, :second), now) == "30s ago"
      assert TimeDisplay.time_ago(DateTime.add(now, -120, :second), now) == "2m ago"
      assert TimeDisplay.time_ago(DateTime.add(now, -7200, :second), now) == "2h ago"
      assert TimeDisplay.time_ago(DateTime.add(now, -172_800, :second), now) == "2d ago"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/fae_web/time_display_test.exs`
Expected: FAIL — `FaeWeb.TimeDisplay` is undefined.

- [ ] **Step 3: Write the implementation (functions only; components added in Task 3)**

```elixir
# lib/fae_web/time_display.ex
defmodule FaeWeb.TimeDisplay do
  @moduledoc """
  The single, enforced chokepoint for rendering dates and times in the
  web UI.

  Every user-facing date/time MUST go through `local_datetime/1`,
  `relative_time/1`, or `format/3`. A custom Credo check
  (`Fae.Credo.Check.UnlocalizedDateTime`) fails the build if any other
  module under `lib/fae_web` calls `Calendar.strftime` or
  `DateTime.to_iso8601` directly.

  All persisted timestamps are UTC; these helpers shift them into the
  user's configured timezone (`Fae.Display`) for display.
  """
  use Phoenix.Component

  @type format :: :date | :datetime | :datetime_seconds | :time

  @doc """
  Format a UTC `DateTime` in `timezone` (an IANA name). Returns "—" for
  nil. Falls back to a UTC render if the zone is unknown.
  """
  @spec format(DateTime.t() | nil, String.t(), format()) :: String.t()
  def format(nil, _timezone, _fmt), do: "—"

  def format(%DateTime{} = utc, timezone, fmt) do
    case DateTime.shift_zone(utc, timezone) do
      {:ok, local} -> render(local, fmt)
      {:error, _reason} -> render(utc, fmt)
    end
  end

  defp render(dt, :date), do: Calendar.strftime(dt, "%Y-%m-%d")
  defp render(dt, :datetime), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M") <> " " <> dt.zone_abbr

  defp render(dt, :datetime_seconds),
    do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S") <> " " <> dt.zone_abbr

  defp render(dt, :time), do: Calendar.strftime(dt, "%H:%M") <> " " <> dt.zone_abbr

  @doc """
  Relative-time label like "2m ago" or "just now" for a past timestamp.
  Returns nil for nil input. Timezone-independent.
  """
  @spec time_ago(DateTime.t() | nil, DateTime.t()) :: String.t() | nil
  def time_ago(at, now \\ DateTime.utc_now())
  def time_ago(nil, _now), do: nil

  def time_ago(%DateTime{} = at, %DateTime{} = now) do
    seconds = DateTime.diff(now, at, :second)

    cond do
      seconds < 5 -> "just now"
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/fae_web/time_display_test.exs`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/fae_web/time_display.ex test/fae_web/time_display_test.exs
git commit -m "Add FaeWeb.TimeDisplay.format/3 + time_ago/2 (pure)"
```

---

### Task 2 note on `DateTime.to_iso8601` in `TimeDisplay`

Task 3 adds components that call `DateTime.to_iso8601/1` for the `<time datetime=…>` attribute. That call lives **inside** `TimeDisplay`, which the Credo check (Task 10) explicitly exempts (`lib/fae_web/time_display.ex`). No other module may call it.

---

### Task 3: `FaeWeb.TimeDisplay` components + global import

**Files:**
- Modify: `lib/fae_web/time_display.ex` (append components)
- Modify: `lib/fae_web.ex` (import into `html_helpers/0`)
- Test: `test/fae_web/time_display_test.exs` (append a component describe block)

- [ ] **Step 1: Write the failing component test (append to the existing file)**

```elixir
  # Append inside test/fae_web/time_display_test.exs, before the final `end`.
  describe "components" do
    import Phoenix.LiveViewTest

    test "local_datetime renders the formatted value with an ISO title" do
      html =
        render_component(&TimeDisplay.local_datetime/1,
          value: ~U[2026-07-01 12:00:00Z],
          tz: "Europe/Amsterdam",
          format: :datetime
        )

      assert html =~ "2026-07-01 14:00 CEST"
      assert html =~ ~s(title="2026-07-01 14:00:00 CEST")
      assert html =~ "2026-07-01T12:00:00Z"
    end

    test "local_datetime renders an em dash for nil" do
      html = render_component(&TimeDisplay.local_datetime/1, value: nil, tz: "UTC")
      assert html =~ "—"
    end

    test "relative_time renders the relative label with an absolute title" do
      html =
        render_component(&TimeDisplay.relative_time/1,
          value: ~U[2026-07-01 12:00:00Z],
          tz: "Europe/Amsterdam",
          id: "last-checked"
        )

      assert html =~ ~s(id="last-checked")
      assert html =~ ~s(title="2026-07-01 14:00:00 CEST")
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/fae_web/time_display_test.exs`
Expected: FAIL — `local_datetime/1` / `relative_time/1` undefined.

- [ ] **Step 3: Append the components to `lib/fae_web/time_display.ex` (before the final `end`)**

```elixir
  attr :value, :any, required: true, doc: "a UTC DateTime, or nil"
  attr :tz, :string, required: true, doc: "IANA timezone name (from @timezone)"

  attr :format, :atom,
    default: :datetime,
    values: [:date, :datetime, :datetime_seconds, :time]

  attr :rest, :global

  @doc "Render a UTC datetime in the user's timezone with a fuller tooltip."
  def local_datetime(assigns) do
    ~H"""
    <time datetime={iso(@value)} title={title(@value, @tz)} {@rest}>{format(@value, @tz, @format)}</time>
    """
  end

  attr :value, :any, required: true, doc: "a UTC DateTime, or nil"
  attr :tz, :string, required: true, doc: "IANA timezone name (from @timezone)"
  attr :rest, :global

  @doc ~S(Render a relative "2m ago" label with the absolute local time as a tooltip.)
  def relative_time(assigns) do
    ~H"""
    <time datetime={iso(@value)} title={title(@value, @tz)} {@rest}>{time_ago(@value)}</time>
    """
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp title(nil, _tz), do: nil
  defp title(%DateTime{} = dt, tz), do: format(dt, tz, :datetime_seconds)
```

- [ ] **Step 4: Import the module into every template context**

In `lib/fae_web.ex`, inside `defp html_helpers do … quote do … end end`, add the import right after the `import FaeWeb.CoreComponents` line:

```elixir
      # Core UI components
      import FaeWeb.CoreComponents
      # The enforced chokepoint for all date/time rendering
      import FaeWeb.TimeDisplay
```

- [ ] **Step 5: Run test + full compile to verify it passes and nothing else broke**

Run: `mix test test/fae_web/time_display_test.exs`
Expected: PASS (12 tests total).
Run: `mix compile --warnings-as-errors`
Expected: clean (no circular-import error — `TimeDisplay` uses `Phoenix.Component`, not `FaeWeb`).

- [ ] **Step 6: Commit**

```bash
git add lib/fae_web/time_display.ex lib/fae_web.ex test/fae_web/time_display_test.exs
git commit -m "Add <.local_datetime>/<.relative_time> and import TimeDisplay globally"
```

---

### Task 4: `FaeWeb.DisplayScope` on_mount hook + router wiring

**Files:**
- Create: `lib/fae_web/live/display_scope.ex`
- Modify: `lib/fae_web/router.ex:14` (the `live_session` `on_mount` list)
- Test: `test/fae_web/live/display_scope_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/fae_web/live/display_scope_test.exs
defmodule FaeWeb.DisplayScopeTest do
  # async: false — drives the shared "settings" PubSub topic + DB.
  use FaeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fae.Display

  test "the hook mounts cleanly and survives a timezone change broadcast", %{conn: conn} do
    {:ok, _} = Display.put_timezone("Europe/Amsterdam")

    {:ok, view, _html} = live(conn, ~p"/")
    assert render(view) =~ "Booted at"

    # Changing the zone broadcasts on "settings"; the attached handle_info
    # hook must update @timezone without crashing the view.
    {:ok, _} = Display.put_timezone("UTC")
    assert render(view) =~ "Booted at"
  end
end
```

> Note: at this point the dashboard still renders dates via raw `Calendar.strftime` (migrated in Task 8), so this test only proves the hook is wired and the broadcast is handled without crashing. The substantive "the page re-renders in the new zone" assertion is added in Task 8 Step 3, once `#boot-at` uses `<.local_datetime tz={@timezone}>`.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/fae_web/live/display_scope_test.exs`
Expected: FAIL — `FaeWeb.DisplayScope` undefined / route still single-hook (no `@timezone`, dashboard still renders raw `Calendar.strftime` until Task 8, so the live-update assertion fails).

> This task wires the hook; the dashboard render is migrated in Task 8. To keep Task 4 independently green, the test above only needs `@timezone` to be assigned and a settings-change to re-render the view. If you prefer strict TDD ordering, you may temporarily assert only `assert render(view)` is a binary after the change, then tighten the assertion in Task 8. Choose the smaller assertion if the dashboard isn't migrated yet.

- [ ] **Step 3: Write the hook**

```elixir
# lib/fae_web/live/display_scope.ex
defmodule FaeWeb.DisplayScope do
  @moduledoc """
  LiveView `on_mount` hook that assigns `@timezone` to every LiveView in
  the default `live_session` and keeps it current.

  On the connected mount it subscribes to the `"settings"` topic and
  attaches a `:handle_info` hook so that changing the timezone (via
  `Fae.Display.put_timezone/1`) re-renders every open page in the new
  zone — satisfying the "LiveViews must be realtime" decision.

  Kept separate from `FaeWeb.SidebarScope` (which holds no persisted
  state). One cheap local-SQLite read per mount is acceptable;
  `Fae.Settings` is designed for direct reads.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  def on_mount(:default, _params, _session, socket) do
    socket = assign(socket, :timezone, Fae.Display.timezone())

    socket =
      if connected?(socket) do
        :ok = Fae.Settings.subscribe()
        attach_hook(socket, :display_timezone, :handle_info, &maybe_update_timezone/2)
      else
        socket
      end

    {:cont, socket}
  end

  defp maybe_update_timezone({:setting_changed, "display", _value}, socket) do
    {:halt, assign(socket, :timezone, Fae.Display.timezone())}
  end

  defp maybe_update_timezone(_message, socket), do: {:cont, socket}
end
```

> Why `{:cont, socket}` for non-matching messages: LiveViews like `UpdateLive` and `DashboardLive` have their own `handle_info/2`. Attached hooks run first; returning `:cont` lets their handlers still fire. Only the `display` settings message is `:halt`ed.

- [ ] **Step 4: Wire the hook into the router**

In `lib/fae_web/router.ex`, change:

```elixir
    live_session :default, on_mount: [FaeWeb.SidebarScope] do
```

to:

```elixir
    live_session :default, on_mount: [FaeWeb.SidebarScope, FaeWeb.DisplayScope] do
```

- [ ] **Step 5: Run test + full suite**

Run: `mix test test/fae_web/live/display_scope_test.exs`
Expected: PASS (using the smaller assertion if dashboard isn't migrated yet).
Run: `mix test`
Expected: PASS (all existing tests still green — `@timezone` is assigned but no template requires it yet).

- [ ] **Step 6: Commit**

```bash
git add lib/fae_web/live/display_scope.ex lib/fae_web/router.ex test/fae_web/live/display_scope_test.exs
git commit -m "Add FaeWeb.DisplayScope: @timezone on every LiveView, live-updated"
```

---

### Task 5: Migrate `PathBrowser` + its three parents to `<.local_datetime>`

`PathBrowser` is a LiveComponent and does **not** get `DisplayScope`, so each parent LiveView must pass `tz={@timezone}` into the `<.live_component>`.

**Files:**
- Modify: `lib/fae_web/components/path_browser.ex:143,183-184`
- Modify: `lib/fae_web/live/backups_live/index.ex:148`
- Modify: `lib/fae_web/live/archive_live/form.ex:295`
- Modify: `lib/fae_web/live/backups_live/job_show.ex:166`

- [ ] **Step 1: Replace the date render in `path_browser.ex`**

Change line 143 from:

```elixir
              {format_size(file.size)} · {format_date(file.last_modified)}
```

to:

```elixir
              {format_size(file.size)} · <.local_datetime value={file.last_modified} tz={@tz} format={:date} />
```

Delete the two `format_date/1` clauses (lines 183-184):

```elixir
  defp format_date(nil), do: "—"
  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")
```

- [ ] **Step 2: Pass `tz` from each parent**

In `lib/fae_web/live/backups_live/index.ex`, `lib/fae_web/live/archive_live/form.ex`, and `lib/fae_web/live/backups_live/job_show.ex`, find the `<.live_component … module={FaeWeb.PathBrowser} id="path-browser" …>` block (around lines 148, 295, 166 respectively) and add an attribute:

```elixir
        tz={@timezone}
```

(Place it on its own line alongside `source=…`, `mode=…`, etc.)

- [ ] **Step 3: Run the relevant tests + compile**

Run: `mix compile --warnings-as-errors`
Expected: clean. (`@tz` is now a required-by-usage assign on the component; passing it from all three parents satisfies it.)
Run: `mix test test/fae_web/live/backups_live_test.exs test/fae_web/live/archive_live_test.exs`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add lib/fae_web/components/path_browser.ex lib/fae_web/live/backups_live/index.ex lib/fae_web/live/archive_live/form.ex lib/fae_web/live/backups_live/job_show.ex
git commit -m "PathBrowser: render dates via <.local_datetime>, tz from parents"
```

---

### Task 6: Migrate backups index + job_show date renders

**Files:**
- Modify: `lib/fae_web/live/backups_live/index.ex:211-216`
- Modify: `lib/fae_web/live/backups_live/job_show.ex:184-187`

- [ ] **Step 1: `backups_live/index.ex` — replace the helper with the component at its call sites**

Find every `format_dt(<dt>)` and `format_dt(<dt>, <enabled?>)` call in the template and replace:

- `format_dt(dt, false)` (the disabled case) stays special — replace the call site with the literal:
  - For a row that may be disabled, render `<.local_datetime value={dt} tz={@timezone} format={:datetime} />` when enabled, and the existing `"(disabled)"` text otherwise. Use the surrounding `:if`/`else` the template already has for enabled state. If the template called `format_dt(next, enabled?)` inline, change it to:

    ```elixir
    <%= if enabled? do %>
      <.local_datetime value={next} tz={@timezone} format={:datetime} />
    <% else %>
      (disabled)
    <% end %>
    ```

- Plain `format_dt(dt)` → `<.local_datetime value={dt} tz={@timezone} format={:datetime} />`.

Then delete the helper clauses (lines 211-216):

```elixir
  defp format_dt(_dt, false), do: "(disabled)"
  defp format_dt(nil, _), do: "—"

  defp format_dt(%DateTime{} = dt, _) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end
```

> Use `grep -n "format_dt" lib/fae_web/live/backups_live/index.ex` first to enumerate every call site so none is missed.

- [ ] **Step 2: `backups_live/job_show.ex` — replace the helper at its call sites**

Replace each `format_dt(dt)` call with `<.local_datetime value={dt} tz={@timezone} format={:datetime_seconds} />` (job_show used `%H:%M:%S`).

Delete the helper clauses (lines 184-187):

```elixir
  defp format_dt(nil), do: "—"

  defp format_dt(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
```

> `format_duration/2` in job_show uses `DateTime.diff` only (no `strftime`/`to_iso8601`) — leave it; the Credo check does not flag it.

- [ ] **Step 3: Run tests + compile**

Run: `mix compile --warnings-as-errors`
Expected: clean.
Run: `mix test test/fae_web/live/backups_live_test.exs`
Expected: PASS (output is identical at the default UTC zone).

- [ ] **Step 4: Commit**

```bash
git add lib/fae_web/live/backups_live/index.ex lib/fae_web/live/backups_live/job_show.ex
git commit -m "Backups index + job_show: render dates via <.local_datetime>"
```

---

### Task 7: Migrate `UpdateLive` (move `time_ago`, route `format_at` through TimeDisplay)

**Files:**
- Modify: `lib/fae_web/live/update_live.ex` (render lines 290, 293-298; helpers 174-191, 242-243)
- Modify: `test/fae_web/live/update_live_test.exs:66-71`

- [ ] **Step 1: Update the failing test first (the function moves modules)**

In `test/fae_web/live/update_live_test.exs`, change the `time_ago` references (lines 66-71) from `UpdateLive.time_ago(...)` to `FaeWeb.TimeDisplay.time_ago(...)`. Add `alias FaeWeb.TimeDisplay` near the top if helpful, then use `TimeDisplay.time_ago(...)`. Example for the block:

```elixir
    test "time_ago/2 buckets sub-minute, minutes, hours, days" do
      now = ~U[2026-05-23 12:00:00Z]

      assert FaeWeb.TimeDisplay.time_ago(nil, now) == nil
      assert FaeWeb.TimeDisplay.time_ago(DateTime.add(now, -2, :second), now) == "just now"
      assert FaeWeb.TimeDisplay.time_ago(DateTime.add(now, -30, :second), now) == "30s ago"
      assert FaeWeb.TimeDisplay.time_ago(DateTime.add(now, -120, :second), now) == "2m ago"
      assert FaeWeb.TimeDisplay.time_ago(DateTime.add(now, -7200, :second), now) == "2h ago"
      assert FaeWeb.TimeDisplay.time_ago(DateTime.add(now, -172_800, :second), now) == "2d ago"
    end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/fae_web/live/update_live_test.exs:63`
Expected: FAIL — `UpdateLive.time_ago` still exists but the test now calls `TimeDisplay.time_ago` (which exists from Task 2) — this test will actually PASS already. So instead, verify the *removal* compiles cleanly in Step 4. (No separate failing step needed here; the behavior moved in Task 2.)

- [ ] **Step 3: Edit `lib/fae_web/live/update_live.ex`**

3a. Delete the `time_ago/2` function (lines 174-191) — it now lives in `TimeDisplay`.

3b. Replace `format_at/1` (lines 242-243) so it no longer calls `Calendar.strftime`:

```elixir
  defp format_at(nil), do: "an unknown time"
  defp format_at(%DateTime{} = dt), do: FaeWeb.TimeDisplay.format(dt, "UTC", :time)
```

> `format_at` is used inside the pure `error_label({:rate_limited, reset_at})` string, which has no socket/timezone in scope. Rendering that one reset time in UTC is acceptable; routing it through `TimeDisplay.format/3` keeps the Credo check satisfied.

3c. Replace the "Published" render (line 290):

```elixir
              <span id="latest-published">
                <.local_datetime value={@latest_release.published_at} tz={@timezone} format={:datetime} />
              </span>
```

3d. Replace the "Last checked" render (lines 293-298):

```elixir
            <%= if @last_check_at do %>
              <span>Last checked</span>
              <.relative_time id="last-checked" value={@last_check_at} tz={@timezone} />
            <% end %>
```

- [ ] **Step 4: Run tests + compile**

Run: `mix compile --warnings-as-errors`
Expected: clean (no unused `time_ago`; `format_at` no longer uses `Calendar`).
Run: `mix test test/fae_web/live/update_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/fae_web/live/update_live.ex test/fae_web/live/update_live_test.exs
git commit -m "UpdateLive: dates via TimeDisplay; move time_ago into TimeDisplay"
```

---

### Task 8: Migrate archive index + dashboard date renders

**Files:**
- Modify: `lib/fae_web/live/archive_live/index.ex:133-134`
- Modify: `lib/fae_web/live/dashboard_live.ex:99-102,280-281`

- [ ] **Step 1: `archive_live/index.ex`**

Replace each `format_dt(dt)` call in the template with `<.local_datetime value={dt} tz={@timezone} format={:datetime} />`, then delete the helper (lines 133-134):

```elixir
  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
```

- [ ] **Step 2: `dashboard_live.ex`**

2a. Replace the "Booted at" render (lines 99-102):

```elixir
        <dt class="text-sm opacity-75">Booted at</dt>
        <dd id="boot-at" class="font-mono">
          <.local_datetime value={@system.boot_at} tz={@timezone} format={:datetime_seconds} />
        </dd>
```

2b. Replace every other `format_dt(dt)` call in the template with `<.local_datetime value={dt} tz={@timezone} format={:datetime} />` (use `grep -n "format_dt" lib/fae_web/live/dashboard_live.ex` to find them), then delete the helper (lines 280-281):

```elixir
  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
```

> `dashboard_view.ex` only does `DateTime.diff` for durations — no `strftime`/`to_iso8601` — so it needs no change.

- [ ] **Step 3: Tighten the Task 4 live-update assertion (now that the dashboard is migrated)**

In `test/fae_web/live/display_scope_test.exs`, ensure the assertions check the dashboard's `#boot-at` re-renders with the new zone (e.g. assert the page contains `" UTC"` after switching to `"UTC"`, and an offset abbreviation when set to `"Europe/Amsterdam"`).

- [ ] **Step 4: Run tests + compile**

Run: `mix compile --warnings-as-errors`
Expected: clean.
Run: `mix test test/fae_web/live/archive_live_test.exs test/fae_web/live/dashboard_live_test.exs test/fae_web/live/display_scope_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/fae_web/live/archive_live/index.ex lib/fae_web/live/dashboard_live.ex test/fae_web/live/display_scope_test.exs
git commit -m "Archive index + dashboard: render dates via <.local_datetime>"
```

---

### Task 9: `FaeWeb.SettingsLive` — page, route, sidebar, JS detect hook

**Files:**
- Create: `lib/fae_web/live/settings_live.ex`
- Modify: `lib/fae_web/router.ex` (add the route)
- Modify: `lib/fae_web/components/sidebar_nav.ex` (add the nav item)
- Test: `test/fae_web/live/settings_live_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/fae_web/live/settings_live_test.exs
defmodule FaeWeb.SettingsLiveTest do
  # async: false — writes go through the shared Fae.Settings table/topic.
  use FaeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fae.Display

  test "shows the current timezone", %{conn: conn} do
    {:ok, _} = Display.put_timezone("Europe/Amsterdam")
    {:ok, _view, html} = live(conn, ~p"/settings")
    assert html =~ ~s(id="current-timezone")
    assert html =~ "Europe/Amsterdam"
  end

  test "saving a zone via the form updates the preference", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#settings form", %{"timezone" => "America/New_York"})
    |> render_submit()

    assert Display.timezone() == "America/New_York"
    assert render(view) =~ "America/New_York"
  end

  test "a detected zone offers a one-click button that saves it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    # Simulate the JS hook pushing the browser's detected zone.
    render_hook(view, "timezone_detected", %{"timezone" => "Europe/Berlin"})
    assert render(view) =~ "Europe/Berlin"

    view |> element("#detected-row button") |> render_click()
    assert Display.timezone() == "Europe/Berlin"
  end

  test "an unknown detected zone offers no button", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    render_hook(view, "timezone_detected", %{"timezone" => "Mars/Phobos"})
    refute render(view) =~ ~s(id="detected-row")
  end

  test "the sidebar exposes a Settings link", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(data-path="/settings")
    assert html =~ ~s(data-tip="Settings")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/fae_web/live/settings_live_test.exs`
Expected: FAIL — route `/settings` does not exist.

- [ ] **Step 3: Create `lib/fae_web/live/settings_live.ex`**

```elixir
defmodule FaeWeb.SettingsLive do
  @moduledoc """
  Settings page. Currently lets the user choose the timezone that all
  dates/times render in across Fae. The choice is persisted via
  `Fae.Display` and broadcast on the `"settings"` topic, so every open
  page re-renders immediately (see `FaeWeb.DisplayScope`).

  A colocated JS hook reports the browser's IANA timezone so the user
  can adopt it in one click; a searchable `<select>` is the manual
  override. `@timezone` (the current value) is supplied by DisplayScope.
  """
  use FaeWeb, :live_view

  alias Fae.Display

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:detected_timezone, nil)
     |> assign(:zone_options, Display.zone_options())}
  end

  @impl true
  def handle_event("timezone_detected", %{"timezone" => tz}, socket) do
    detected = if Display.valid_timezone?(tz), do: tz, else: nil
    {:noreply, assign(socket, :detected_timezone, detected)}
  end

  def handle_event("use_detected", _params, socket) do
    case socket.assigns.detected_timezone do
      nil -> {:noreply, socket}
      tz -> save(socket, tz)
    end
  end

  def handle_event("save", %{"timezone" => tz}, socket) do
    save(socket, tz)
  end

  defp save(socket, tz) do
    case Display.put_timezone(tz) do
      {:ok, _tz} -> {:noreply, put_flash(socket, :info, "Timezone updated.")}
      {:error, :invalid_timezone} -> {:noreply, put_flash(socket, :error, "Unknown timezone.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <section id="settings" class="space-y-6 max-w-xl">
        <header class="space-y-1">
          <h1 class="text-2xl font-semibold">Settings</h1>
          <p class="text-sm opacity-75">Preferences for this Fae instance.</p>
        </header>

        <div id="timezone-card" class="card bg-base-200 p-4 space-y-3">
          <h2 class="text-lg font-medium">Timezone</h2>
          <p class="text-sm opacity-75">
            All dates and times across Fae are shown in this timezone. Current:
            <span id="current-timezone" class="font-mono">{@timezone}</span>
          </p>

          <div id="tz-detector" phx-hook=".TimezoneDetect"></div>

          <div :if={@detected_timezone} id="detected-row" class="flex items-center gap-3">
            <span class="text-sm">
              Detected: <span class="font-mono">{@detected_timezone}</span>
            </span>
            <button type="button" class="btn btn-soft btn-success btn-sm" phx-click="use_detected">
              Use this
            </button>
          </div>

          <form phx-submit="save" class="flex items-end gap-2">
            <div class="flex-1">
              <.input
                type="select"
                id="timezone-select"
                name="timezone"
                label="Pick manually"
                value={@timezone}
                options={@zone_options}
              />
            </div>
            <button type="submit" class="btn btn-primary">Save</button>
          </form>
        </div>
      </section>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".TimezoneDetect">
        export default {
          mounted() {
            const tz = Intl.DateTimeFormat().resolvedOptions().timeZone
            if (tz) this.pushEvent("timezone_detected", {timezone: tz})
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 4: Add the route**

In `lib/fae_web/router.ex`, inside the `live_session :default` block, add alongside the other top-level routes:

```elixir
      live "/settings", SettingsLive, :index
```

- [ ] **Step 5: Add the sidebar nav item**

In `lib/fae_web/components/sidebar_nav.ex`, append a new group to `@groups` (after the Updates group):

```elixir
    %{
      items: [
        %{path: "/settings", label: "Settings", icon: "hero-cog-6-tooth"}
      ]
    }
```

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test test/fae_web/live/settings_live_test.exs`
Expected: PASS (5 tests).
Run: `mix test test/fae_web/live/sidebar_test.exs`
Expected: PASS (existing sidebar assertions still hold; new item is additive).

- [ ] **Step 7: Commit**

```bash
git add lib/fae_web/live/settings_live.ex lib/fae_web/router.ex lib/fae_web/components/sidebar_nav.ex test/fae_web/live/settings_live_test.exs
git commit -m "Add Settings page: timezone picker with browser detect + override"
```

---

### Task 10: Custom Credo check enforcing the chokepoint

**Files:**
- Modify: `mix.exs` (add `credo` dep, extend `elixirc_paths`, add `credo` to `precommit`)
- Create: `.credo.exs`
- Create: `credo_checks/fae/credo/check/unlocalized_date_time.ex`
- Test: `test/fae/credo/check/unlocalized_date_time_test.exs`

- [ ] **Step 1: Add the dep and compile paths in `mix.exs`**

1a. Add to `deps/0`:

```elixir
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
```

1b. Replace `elixirc_paths/1` (lines 45-46) with:

```elixir
  defp elixirc_paths(:test), do: ["lib", "test/support", "credo_checks"]
  defp elixirc_paths(:dev), do: ["lib", "credo_checks"]
  defp elixirc_paths(_), do: ["lib"]
```

> The check uses `use Credo.Check`, which only exists when Credo is loaded. Keeping it under `credo_checks/` (compiled in dev/test only) ensures it is never compiled in `:prod`, where Credo is absent.

- [ ] **Step 2: Fetch the dep**

Run: `mix deps.get`
Expected: credo (and its dep `bunt`/`file_system` as applicable) resolved.

- [ ] **Step 3: Write the failing check test**

```elixir
# test/fae/credo/check/unlocalized_date_time_test.exs
defmodule Fae.Credo.Check.UnlocalizedDateTimeTest do
  use Credo.Test.Case

  alias Fae.Credo.Check.UnlocalizedDateTime

  test "flags Calendar.strftime in a web module" do
    """
    defmodule FaeWeb.Foo do
      def f(dt), do: Calendar.strftime(dt, "%Y-%m-%d")
    end
    """
    |> to_source_file("lib/fae_web/foo.ex")
    |> run_check(UnlocalizedDateTime)
    |> assert_issue()
  end

  test "flags DateTime.to_iso8601 in a web module" do
    """
    defmodule FaeWeb.Foo do
      def f(dt), do: DateTime.to_iso8601(dt)
    end
    """
    |> to_source_file("lib/fae_web/foo.ex")
    |> run_check(UnlocalizedDateTime)
    |> assert_issue()
  end

  test "does not flag the TimeDisplay module itself" do
    """
    defmodule FaeWeb.TimeDisplay do
      def f(dt), do: Calendar.strftime(dt, "%Y-%m-%d")
    end
    """
    |> to_source_file("lib/fae_web/time_display.ex")
    |> run_check(UnlocalizedDateTime)
    |> refute_issues()
  end

  test "does not flag domain (non-web) modules" do
    """
    defmodule Fae.Backups.Packager do
      def f(dt), do: Calendar.strftime(dt, "%Y-%m-%d")
    end
    """
    |> to_source_file("lib/fae/backups/packager.ex")
    |> run_check(UnlocalizedDateTime)
    |> refute_issues()
  end

  test "passes clean web code that uses TimeDisplay" do
    """
    defmodule FaeWeb.Foo do
      def f(dt, tz), do: FaeWeb.TimeDisplay.format(dt, tz, :datetime)
    end
    """
    |> to_source_file("lib/fae_web/foo.ex")
    |> run_check(UnlocalizedDateTime)
    |> refute_issues()
  end
end
```

- [ ] **Step 4: Run it to verify it fails**

Run: `mix test test/fae/credo/check/unlocalized_date_time_test.exs`
Expected: FAIL — `Fae.Credo.Check.UnlocalizedDateTime` undefined.

- [ ] **Step 5: Write the check**

```elixir
# credo_checks/fae/credo/check/unlocalized_date_time.ex
defmodule Fae.Credo.Check.UnlocalizedDateTime do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      All user-facing dates/times must render in the user's timezone via
      FaeWeb.TimeDisplay — `<.local_datetime>`, `<.relative_time>`, or
      `TimeDisplay.format/3`.

      Calling `Calendar.strftime` or `DateTime.to_iso8601` directly under
      `lib/fae_web` bypasses the timezone guard-rail and risks showing a
      raw UTC value to the user.
      """
    ]

  @forbidden [
    {[:Calendar], :strftime},
    {[:DateTime], :to_iso8601}
  ]

  @impl true
  def run(%Credo.SourceFile{} = source_file, params) do
    if scoped?(source_file.filename) do
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    else
      []
    end
  end

  # Only files under lib/fae_web, and never TimeDisplay itself.
  defp scoped?(filename) do
    String.contains?(filename, "lib/fae_web/") and
      not String.ends_with?(filename, "time_display.ex")
  end

  for {mod, fun} <- @forbidden do
    trigger = Enum.join(unquote(mod), ".") <> "." <> Atom.to_string(unquote(fun))

    defp traverse(
           {{:., meta, [{:__aliases__, _, unquote(mod)}, unquote(fun)]}, _, _args} = ast,
           issues,
           issue_meta
         ) do
      {ast, [issue_for(meta[:line], unquote(trigger), issue_meta) | issues]}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp issue_for(line_no, trigger, issue_meta) do
    format_issue(
      issue_meta,
      message: "Use FaeWeb.TimeDisplay instead of #{trigger} for user-facing dates/times.",
      trigger: trigger,
      line_no: line_no
    )
  end
end
```

> `IssueMeta`, `Credo.SourceFile`, `Credo.Code`, and `format_issue/2` are all provided/aliased by `use Credo.Check`.

- [ ] **Step 6: Run the check test to verify it passes**

Run: `mix test test/fae/credo/check/unlocalized_date_time_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 7: Add `.credo.exs` running only this check**

```elixir
# .credo.exs
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "credo_checks/"],
        excluded: []
      },
      # Only Fae's custom checks run in the gate. Adopting Credo's full
      # default ruleset is a separate, later decision.
      checks: [
        {Fae.Credo.Check.UnlocalizedDateTime, []}
      ]
    }
  ]
}
```

- [ ] **Step 8: Verify the check is clean against the real tree**

Run: `mix credo --only Fae.Credo`
Expected: no issues (Tasks 5-8 removed every raw date call under `lib/fae_web`). If a `Calendar.strftime`/`DateTime.to_iso8601` is reported, fix that call site to use `TimeDisplay` and re-run.

> The `--only Fae.Credo` flag guarantees only our check runs even if Credo's config semantics would otherwise include defaults.

- [ ] **Step 9: Wire it into the precommit gate**

In `mix.exs`, change the `precommit` alias (line 102) to append credo before `test`:

```elixir
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --only Fae.Credo",
        "test"
      ]
```

- [ ] **Step 10: Run the full gate**

Run: `mix precommit`
Expected: PASS — compile clean, format clean, credo clean, all tests green.

- [ ] **Step 11: Commit**

```bash
git add mix.exs mix.lock .credo.exs credo_checks/fae/credo/check/unlocalized_date_time.ex test/fae/credo/check/unlocalized_date_time_test.exs
git commit -m "Enforce localized dates: custom Credo check in the precommit gate"
```

---

### Task 11: Final verification

- [ ] **Step 1: Full gate, clean build**

Run: `just check`
Expected: PASS (this runs `mix precommit`).

- [ ] **Step 2: Manual smoke (optional, dev server)**

Run: `just dev` (or `mix phx.server`), open <http://127.0.0.1:4321/settings>, confirm:
- "Detected: …" shows your browser zone; clicking "Use this" updates "Current" and every page's timestamps.
- Picking a zone manually + Save does the same.
- Navigating to `/`, `/backups`, `/archive`, `/update` shows times with the chosen zone's abbreviation.

- [ ] **Step 3: Confirm the guard-rail bites**

Temporarily add `Calendar.strftime(DateTime.utc_now(), "%Y")` to any `lib/fae_web` module, run `mix credo --only Fae.Credo`, confirm it reports an issue, then revert.

---

## Self-Review

**Spec coverage:**
- §1 `Fae.Display` → Task 1 ✓
- §2 `FaeWeb.TimeDisplay` (pure + components) → Tasks 2, 3 ✓
- §3 `FaeWeb.DisplayScope` + router → Task 4 ✓
- §4 `FaeWeb.SettingsLive` + route + sidebar + JS detect hook → Task 9 ✓
- §5 custom Credo check + dep + `.credo.exs` + precommit → Task 10 ✓
- §6 refactor all six render sites → Tasks 5 (path_browser + parents), 6 (backups), 7 (update_live), 8 (archive + dashboard) ✓
- §7 out-of-scope (domain stays UTC) → Credo `scoped?/1` restricts to `lib/fae_web`; verified by Task 10 Step 3 test ✓
- Error handling (invalid zone, nil, unknown detected, shift_zone failure) → Tasks 1, 2, 9 ✓
- Testing (Display, TimeDisplay incl. DST, SettingsLive/DisplayScope, the check itself) → Tasks 1-4, 9, 10 ✓

**Type/name consistency:**
- `Fae.Display.timezone/0`, `put_timezone/1`, `valid_timezone?/1`, `zone_options/0`, `default_timezone/0` — used consistently in Tasks 1, 4, 9.
- `FaeWeb.TimeDisplay.format/3` (`:date | :datetime | :datetime_seconds | :time`), `time_ago/2`, `local_datetime/1`, `relative_time/1` — consistent across Tasks 2, 3, 5-9.
- `@timezone` assign — produced by `DisplayScope` (Task 4), consumed by every `<.local_datetime tz={@timezone}>` (Tasks 5-9) and `SettingsLive` (Task 9). `PathBrowser` receives it as `@tz` from parents (Task 5).
- Settings key `"display"`, value `%{"timezone" => …}` — consistent in Tasks 1, 4.
- Credo module `Fae.Credo.Check.UnlocalizedDateTime` — consistent in Task 10 and its test; `--only Fae.Credo` matches it.

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every run step states the command and expected result. The only "judgment" step is Task 4 Step 2's assertion tightness, which is explicitly explained and then tightened in Task 8 Step 3.
