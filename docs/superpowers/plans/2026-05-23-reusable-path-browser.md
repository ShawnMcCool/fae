# Reusable Path Browser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the Archive form's inline folder-picker into a reusable `FaeWeb.PathBrowser` LiveComponent (pick + view modes, per-use file visibility) and wire it into the Backups job view as a view-only remote browser.

**Architecture:** A stateful `Phoenix.LiveComponent` owns the modal, navigation state, and `start_async` loading; it sends two messages back to the parent (`:selected`, `:closed`). A pure `FaeWeb.PathBrowser.Source` module does one-level listing (folders + optional files-with-metadata) and path math, delegating remote listing to the storage driver. The S3 driver's `list_prefixes/2` is enriched to return file metadata.

**Tech Stack:** Elixir, Phoenix LiveView 1.1, Mox (driver mock), ExUnit.

**Spec:** `docs/superpowers/specs/2026-05-23-reusable-path-browser-design.md`

---

## File Structure

- `lib/fae/storage/drivers/driver.ex` — modify `list_prefixes` callback type (`keys` → `files` with metadata).
- `lib/fae/storage/drivers/s3.ex` — modify `parse_prefixes/1` + `list_prefixes_paginated/4` to carry file size/last_modified.
- `lib/fae_web/components/path_browser/source.ex` — **new** pure backend (promoted from `ArchiveLive.Picker`).
- `lib/fae_web/components/path_browser.ex` — **new** stateful LiveComponent (modal + state machine + async).
- `lib/fae_web/live/archive_live/form.ex` — modify: replace inline picker with the component.
- `lib/fae_web/live/archive_live/picker.ex` — **delete** (logic moved to Source).
- `lib/fae_web/live/backups_live/job_show.ex` — modify: add "Browse backups" button + component.
- Tests: new `test/fae/storage/drivers/s3_test.exs`, new `test/fae_web/components/path_browser/source_test.exs`; modify `test/fae_web/live/archive_live_test.exs`, `test/fae_web/live/backups_live_test.exs`, `test/fae/storage/drivers/s3_integration_test.exs`; **delete** `test/fae_web/live/archive_live/picker_test.exs`.

---

## Task 1: Enrich the driver's one-level listing to return file metadata

**Files:**
- Modify: `lib/fae/storage/drivers/s3.ex` (`parse_prefixes/1` ~520-539, `list_prefixes/2` + `list_prefixes_paginated/4` ~269-302)
- Modify: `lib/fae/storage/drivers/driver.ex:49-56`
- Test: `test/fae/storage/drivers/s3_test.exs` (new)
- Modify: `test/fae/storage/drivers/s3_integration_test.exs:104-121`

- [ ] **Step 1: Write the failing test**

Create `test/fae/storage/drivers/s3_test.exs`:

```elixir
defmodule Fae.Storage.Drivers.S3Test do
  use ExUnit.Case, async: true

  alias Fae.Storage.Drivers.S3

  describe "parse_prefixes/1" do
    test "extracts sub-folders and files with size and last-modified" do
      xml = """
      <ListBucketResult>
        <CommonPrefixes><Prefix>lp/a/</Prefix></CommonPrefixes>
        <Contents>
          <Key>lp/top.txt</Key>
          <LastModified>2026-05-01T12:00:00.000Z</LastModified>
          <Size>42</Size>
        </Contents>
      </ListBucketResult>
      """

      {prefixes, files, next} = S3.parse_prefixes(xml)

      assert prefixes == ["lp/a/"]
      assert [%{key: "lp/top.txt", size: 42, last_modified: %DateTime{} = dt}] = files
      assert DateTime.to_date(dt) == ~D[2026-05-01]
      assert next == nil
    end

    test "returns a continuation token when present" do
      xml = """
      <ListBucketResult>
        <NextContinuationToken>tok</NextContinuationToken>
      </ListBucketResult>
      """

      assert {[], [], "tok"} = S3.parse_prefixes(xml)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/fae/storage/drivers/s3_test.exs`
Expected: FAIL — `parse_prefixes/1` returns `{prefixes, keys, next}` where `keys` are strings, so the `%{key:, size:, last_modified:}` match fails.

- [ ] **Step 3: Implement the driver changes**

In `lib/fae/storage/drivers/s3.ex`, replace `parse_prefixes/1` (the `@doc false def parse_prefixes` clause) with:

```elixir
  # One-level (delimiter=/) listing: CommonPrefixes are the sub-folders,
  # Contents are the files at this level (with size + last-modified).
  @doc false
  def parse_prefixes(xml) when is_binary(xml) do
    prefixes =
      ~r{<CommonPrefixes>.*?<Prefix>(.*?)</Prefix>.*?</CommonPrefixes>}s
      |> Regex.scan(xml, capture: :all_but_first)
      |> Enum.map(fn [prefix] -> prefix end)

    files =
      ~r{<Contents>(.*?)</Contents>}s
      |> Regex.scan(xml, capture: :all_but_first)
      |> Enum.map(fn [content] ->
        %{
          key: extract(content, "Key"),
          size: extract(content, "Size") |> String.to_integer(),
          last_modified: parse_datetime(extract(content, "LastModified"))
        }
      end)

    next_token =
      case Regex.run(~r{<NextContinuationToken>(.*?)</NextContinuationToken>}s, xml) do
        [_, token] -> token
        _ -> nil
      end

    {prefixes, files, next_token}
  end
```

Replace `list_prefixes/2` and `list_prefixes_paginated/4`:

```elixir
  @impl true
  def list_prefixes(%Destination{} = dest, prefix) do
    list_prefixes_paginated(dest, prefix, nil, [], [])
  end

  defp list_prefixes_paginated(dest, prefix, continuation, prefixes, files) do
    base = "#{bucket_url(dest)}/"

    params =
      [{"list-type", "2"}, {"delimiter", "/"}, {"prefix", prefix}]
      |> add_continuation(continuation)

    url = "#{base}?#{encode_query(params)}"
    signed = sign(dest, "GET", url, base_headers(url), "")

    case Req.get(url, headers: signed) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {page_prefixes, page_files, next_token} = parse_prefixes(body)
        prefixes = prefixes ++ page_prefixes
        files = files ++ page_files

        if next_token do
          list_prefixes_paginated(dest, prefix, next_token, prefixes, files)
        else
          {:ok, %{prefixes: prefixes, files: files}}
        end

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:s3_error, status, response_body}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end
```

In `lib/fae/storage/drivers/driver.ex`, replace the `list_prefixes` callback (lines 49-56):

```elixir
  @doc """
  Lists a single level of the keyspace under `prefix` using
  `delimiter=/`: the immediate sub-folders (`prefixes`, from S3
  CommonPrefixes) and the files at this level (`files`, with size and
  last-modified). Powers the path browser.
  """
  @callback list_prefixes(Destination.t(), prefix :: String.t()) ::
              {:ok, %{prefixes: [String.t()], files: [object()]}} | {:error, term()}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/fae/storage/drivers/s3_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Update the integration test to the new shape**

In `test/fae/storage/drivers/s3_integration_test.exs`, replace lines 113-117:

```elixir
    {:ok, %{prefixes: prefixes, files: files}} = S3.list_prefixes(dest, "lp/")
    assert "lp/a/" in prefixes
    assert Enum.any?(files, &(&1.key == "lp/top.txt"))
    # Nested entries are NOT flattened into this level.
    refute Enum.any?(files, &(&1.key == "lp/a/x.txt"))
```

- [ ] **Step 6: Run the full suite (integration excluded) to confirm nothing else broke**

Run: `mix test`
Expected: PASS. (`ArchiveLive.Picker.list_remote/2` only reads `prefixes`, so it is unaffected by the `keys`→`files` rename.)

- [ ] **Step 7: Commit**

```bash
git add lib/fae/storage/drivers/s3.ex lib/fae/storage/drivers/driver.ex test/fae/storage/drivers/s3_test.exs test/fae/storage/drivers/s3_integration_test.exs
git commit -m "Return file size + last-modified from list_prefixes"
```

---

## Task 2: Create the pure `FaeWeb.PathBrowser.Source` backend

**Files:**
- Create: `lib/fae_web/components/path_browser/source.ex`
- Test: `test/fae_web/components/path_browser/source_test.exs` (new)

- [ ] **Step 1: Write the failing test**

Create `test/fae_web/components/path_browser/source_test.exs`:

```elixir
defmodule FaeWeb.PathBrowser.SourceTest do
  # async: false — list_remote/3 resolves the driver via :storage_drivers
  # application env, which is global state.
  use ExUnit.Case, async: false

  import Mox

  alias Fae.Storage.Destination
  alias Fae.Storage.Drivers.DriverMock
  alias FaeWeb.PathBrowser.Source

  setup :verify_on_exit!

  describe "list/2 local" do
    @tag :tmp_dir
    test "folders sorted; files hidden when show_files? is false", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join(tmp, "b"))
      File.mkdir_p!(Path.join(tmp, "a"))
      File.write!(Path.join(tmp, "file.txt"), "xy")

      assert {:ok, %{folders: ["a", "b"], files: []}} = Source.list({:local, tmp}, false)
    end

    @tag :tmp_dir
    test "files include size and last-modified when show_files? is true", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join(tmp, "d"))
      File.write!(Path.join(tmp, "file.txt"), "xy")

      assert {:ok, %{folders: ["d"], files: [file]}} = Source.list({:local, tmp}, true)
      assert file.name == "file.txt"
      assert file.size == 2
      assert %DateTime{} = file.last_modified
    end

    test "errors on a missing path" do
      assert {:error, _} = Source.list({:local, "/no/such/dir/anywhere"}, false)
    end
  end

  describe "path helpers" do
    test "down/up for local and remote" do
      assert Source.down(:local, "/a", "b") == "/a/b"
      assert Source.down(:remote, "", "a") == "a"
      assert Source.down(:remote, "a", "b") == "a/b"
      assert Source.up(:local, "/a/b") == "/a"
      assert Source.up(:remote, "a/b/c") == "a/b"
      assert Source.up(:remote, "a") == ""
    end

    test "location_label" do
      assert Source.location_label(:local, "/a/b") == "/a/b"
      assert Source.location_label(:remote, "") == "(top level)"
      assert Source.location_label(:remote, "a/b") == "a/b"
    end

    test "remote_s3_prefix joins the destination prefix and relative path" do
      assert Source.remote_s3_prefix(%Destination{path_prefix: "Family"}, "") == "Family/"
      assert Source.remote_s3_prefix(%Destination{path_prefix: "Family"}, "Pics") == "Family/Pics/"
      assert Source.remote_s3_prefix(%Destination{path_prefix: ""}, "") == ""
      assert Source.remote_s3_prefix(%Destination{path_prefix: ""}, "Pics") == "Pics/"
    end

    test "relativize strips the current prefix to leaf names" do
      listing = %{
        prefixes: ["Family/Pictures Videos/", "Family/Documents/"],
        files: [%{key: "Family/note.txt", size: 5, last_modified: ~U[2026-05-01 00:00:00Z]}]
      }

      assert %{folders: ["Documents", "Pictures Videos"], files: [file]} =
               Source.relativize(listing, "Family/", true)

      assert file.name == "note.txt"
      assert file.size == 5

      assert %{files: []} = Source.relativize(listing, "Family/", false)
    end
  end

  describe "list/2 remote" do
    setup do
      Application.put_env(:fae, :storage_drivers, %{"s3" => DriverMock})
      on_exit(fn -> Application.delete_env(:fae, :storage_drivers) end)
      :ok
    end

    test "maps driver listing to leaf folder names, sorted" do
      dest = %Destination{driver: "s3", path_prefix: "Family"}

      expect(DriverMock, :list_prefixes, fn ^dest, "Family/" ->
        {:ok, %{prefixes: ["Family/Pictures Videos/", "Family/Documents/"], files: []}}
      end)

      assert {:ok, %{folders: ["Documents", "Pictures Videos"]}} =
               Source.list({:remote, dest, ""}, false)
    end

    test "propagates driver errors" do
      dest = %Destination{driver: "s3", path_prefix: ""}
      expect(DriverMock, :list_prefixes, fn ^dest, "" -> {:error, :forbidden} end)
      assert {:error, :forbidden} = Source.list({:remote, dest, ""}, false)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/fae_web/components/path_browser/source_test.exs`
Expected: FAIL — `FaeWeb.PathBrowser.Source` does not exist.

- [ ] **Step 3: Create the Source module**

Create `lib/fae_web/components/path_browser/source.ex`:

```elixir
defmodule FaeWeb.PathBrowser.Source do
  @moduledoc """
  Backend for `FaeWeb.PathBrowser`: list one level of a tree — the local
  filesystem or a destination's bucket — plus the path math for
  navigating up and down.

  Object storage has no real directories, so the remote side uses
  delimiter listing (CommonPrefixes) via the driver, browsing relative
  to the destination's `path_prefix`. `relativize/3` turns the driver's
  full prefixes/keys into leaf names (carrying file size + last-modified)
  for display.
  """
  alias Fae.Storage.Destination
  alias Fae.Storage.Drivers

  @type entry :: %{name: String.t(), size: non_neg_integer(), last_modified: DateTime.t() | nil}
  @type listing :: %{folders: [String.t()], files: [entry()]}
  @type source :: {:local, String.t()} | {:remote, Destination.t(), String.t()}

  @doc "One level of folders (always) and files (when `show_files?`)."
  @spec list(source(), boolean()) :: {:ok, listing()} | {:error, term()}
  def list({:local, path}, show_files?), do: list_local(path, show_files?)
  def list({:remote, dest, rel}, show_files?), do: list_remote(dest, rel, show_files?)

  defp list_local(path, show_files?) do
    case File.ls(path) do
      {:ok, names} ->
        {dirs, files} = Enum.split_with(names, &File.dir?(Path.join(path, &1)))
        {:ok, %{folders: Enum.sort(dirs), files: local_files(path, files, show_files?)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp local_files(_path, _names, false), do: []

  defp local_files(path, names, true) do
    names
    |> Enum.sort()
    |> Enum.map(fn name ->
      stat = File.stat!(Path.join(path, name), time: :posix)
      %{name: name, size: stat.size, last_modified: DateTime.from_unix!(stat.mtime)}
    end)
  end

  defp list_remote(%Destination{} = dest, rel, show_files?) do
    s3_prefix = remote_s3_prefix(dest, rel)
    driver = Drivers.driver_for(dest)

    case driver.list_prefixes(dest, s3_prefix) do
      {:ok, listing} -> {:ok, relativize(listing, s3_prefix, show_files?)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Turn the driver's full prefixes/keys into leaf names relative to `s3_prefix`."
  @spec relativize(map(), String.t(), boolean()) :: listing()
  def relativize(%{prefixes: prefixes} = listing, s3_prefix, show_files?) do
    folders =
      prefixes
      |> Enum.map(fn full ->
        full |> String.trim_trailing("/") |> String.replace_prefix(s3_prefix, "")
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.sort()

    %{folders: folders, files: relativize_files(listing[:files] || [], s3_prefix, show_files?)}
  end

  defp relativize_files(_files, _s3_prefix, false), do: []

  defp relativize_files(files, s3_prefix, true) do
    files
    |> Enum.map(fn file ->
      %{
        name: String.replace_prefix(file.key, s3_prefix, ""),
        size: file.size,
        last_modified: file.last_modified
      }
    end)
    |> Enum.reject(&(&1.name == ""))
    |> Enum.sort_by(& &1.name)
  end

  @doc ~S"""
  The S3 key prefix (trailing slash, or "" at the root) for a destination
  plus a relative browse path.
  """
  @spec remote_s3_prefix(Destination.t(), String.t()) :: String.t()
  def remote_s3_prefix(%Destination{} = dest, rel) do
    [dest.path_prefix, rel]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("/")
    |> case do
      "" -> ""
      joined -> joined <> "/"
    end
  end

  @doc "Descend into `name` from the current location."
  @spec down(:local | :remote, String.t(), String.t()) :: String.t()
  def down(:local, path, name), do: Path.join(path, name)
  def down(:remote, "", name), do: name
  def down(:remote, rel, name), do: rel <> "/" <> name

  @doc "Ascend one level from the current location."
  @spec up(:local | :remote, String.t()) :: String.t()
  def up(:local, path), do: Path.dirname(path)
  def up(:remote, rel), do: rel |> String.split("/", trim: true) |> Enum.drop(-1) |> Enum.join("/")

  @doc "Human label for the current location."
  @spec location_label(:local | :remote, String.t()) :: String.t()
  def location_label(:local, path), do: path
  def location_label(:remote, ""), do: "(top level)"
  def location_label(:remote, rel), do: rel
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/fae_web/components/path_browser/source_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/fae_web/components/path_browser/source.ex test/fae_web/components/path_browser/source_test.exs
git commit -m "Add PathBrowser.Source: one-level local/remote listing + path math"
```

---

## Task 3: Create the `FaeWeb.PathBrowser` LiveComponent

**Files:**
- Create: `lib/fae_web/components/path_browser.ex`

(No standalone test — the component is exercised by the integration tests in Tasks 4 and 5. This task only adds the module and confirms it compiles.)

- [ ] **Step 1: Create the component**

Create `lib/fae_web/components/path_browser.ex`:

```elixir
defmodule FaeWeb.PathBrowser do
  @moduledoc """
  A reusable folder/file browser modal.

  Render it from a parent LiveView only while a browse is open:

      <.live_component
        :if={@browser}
        module={FaeWeb.PathBrowser} id="path-browser"
        source={@browser.source}        # {:local, path} | {:remote, %Destination{}, rel}
        mode={@browser.mode}            # :pick | :view
        show_files={@browser.show_files}
        title={@browser.title}
        return_to={@browser.return_to}  # opaque tag echoed back on select
      />

  It owns its own navigation state and loads each level with `start_async`.
  It sends two messages to the parent process (a LiveComponent runs in the
  parent's process, so `self()` is the parent LiveView):

    * `{:path_browser, :selected, return_to, value}` — only in `:pick`
      mode; `value` is the chosen local path or remote rel.
    * `{:path_browser, :closed}` — cancel / backdrop / close.
  """
  use FaeWeb, :live_component

  alias FaeWeb.PathBrowser.Source

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if socket.assigns[:initialized?] do
      {:ok, socket}
    else
      {kind, dest, loc} = init_location(assigns.source)

      socket =
        socket
        |> assign(
          kind: kind,
          dest: dest,
          loc: loc,
          folders: [],
          files: [],
          loading: true,
          error: nil,
          initialized?: true
        )
        |> load()

      {:ok, socket}
    end
  end

  defp init_location({:local, path}), do: {:local, nil, path}
  defp init_location({:remote, dest, rel}), do: {:remote, dest, rel}

  @impl true
  def handle_event("navigate", %{"name" => name}, socket) do
    loc = Source.down(socket.assigns.kind, socket.assigns.loc, name)
    {:noreply, socket |> assign(:loc, loc) |> load()}
  end

  def handle_event("up", _params, socket) do
    loc = Source.up(socket.assigns.kind, socket.assigns.loc)
    {:noreply, socket |> assign(:loc, loc) |> load()}
  end

  def handle_event("select", _params, socket) do
    send(self(), {:path_browser, :selected, socket.assigns.return_to, socket.assigns.loc})
    {:noreply, socket}
  end

  def handle_event("close", _params, socket) do
    send(self(), {:path_browser, :closed})
    {:noreply, socket}
  end

  @impl true
  def handle_async(:load, {:ok, {:ok, listing}}, socket) do
    {:noreply, assign(socket, folders: listing.folders, files: listing.files, loading: false)}
  end

  def handle_async(:load, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, loading: false, error: inspect(reason))}
  end

  def handle_async(:load, {:exit, reason}, socket) do
    {:noreply, assign(socket, loading: false, error: inspect(reason))}
  end

  # `start_async` "later wins" semantics is exactly what we want: a rapid
  # sequence of navigations resolves to the last location's listing.
  defp load(socket) do
    source = source_tuple(socket)
    show_files? = socket.assigns.show_files
    socket = assign(socket, loading: true, error: nil)
    start_async(socket, :load, fn -> Source.list(source, show_files?) end)
  end

  defp source_tuple(%{assigns: %{kind: :local, loc: loc}}), do: {:local, loc}
  defp source_tuple(%{assigns: %{kind: :remote, dest: dest, loc: loc}}), do: {:remote, dest, loc}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-lg">
        <h3 class="text-lg font-semibold mb-1">{@title}</h3>
        <div class="text-xs opacity-60 font-mono mb-3 break-all">
          {Source.location_label(@kind, @loc)}
        </div>

        <div :if={@error} class="alert alert-error text-sm mb-2">{@error}</div>

        <div class="max-h-72 overflow-y-auto border border-base-300 rounded">
          <button
            type="button"
            phx-click="up"
            phx-target={@myself}
            class="block w-full text-left px-3 py-1.5 hover:bg-base-300 text-sm"
          >
            ../ (up)
          </button>
          <div :if={@loading} class="px-3 py-2 text-sm opacity-60">Loading…</div>
          <button
            :for={folder <- @folders}
            type="button"
            phx-click="navigate"
            phx-value-name={folder}
            phx-target={@myself}
            class="block w-full text-left px-3 py-1.5 hover:bg-base-300 text-sm font-mono"
          >
            📁 {folder}
          </button>
          <div
            :for={file <- @files}
            class="flex items-center justify-between gap-3 px-3 py-1.5 text-sm font-mono"
          >
            <span class="truncate">📄 {file.name}</span>
            <span class="opacity-60 text-xs whitespace-nowrap">
              {format_size(file.size)} · {format_date(file.last_modified)}
            </span>
          </div>
          <div
            :if={not @loading and @folders == [] and @files == []}
            class="px-3 py-2 text-sm opacity-60"
          >
            Nothing here.
          </div>
        </div>

        <div class="flex justify-end gap-2 mt-3">
          <button type="button" phx-click="close" phx-target={@myself} class="btn btn-ghost">
            {if @mode == :view, do: "Close", else: "Cancel"}
          </button>
          <button
            :if={@mode == :pick}
            type="button"
            phx-click="select"
            phx-target={@myself}
            class="btn btn-primary"
          >
            Use this folder
          </button>
        </div>
      </div>
      <label class="modal-backdrop" phx-click="close" phx-target={@myself}>Close</label>
    </div>
    """
  end

  defp format_size(nil), do: "—"
  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KiB"

  defp format_size(bytes) when bytes < 1_073_741_824,
    do: "#{Float.round(bytes / 1_048_576, 1)} MiB"

  defp format_size(bytes), do: "#{Float.round(bytes / 1_073_741_824, 2)} GiB"

  defp format_date(nil), do: "—"
  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")
end
```

- [ ] **Step 2: Confirm it compiles with no warnings**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean.

- [ ] **Step 3: Commit**

```bash
git add lib/fae_web/components/path_browser.ex
git commit -m "Add PathBrowser LiveComponent (pick + view modes)"
```

---

## Task 4: Rewire the Archive form to use the component; delete the old Picker

**Files:**
- Modify: `lib/fae_web/live/archive_live/form.ex`
- Modify: `test/fae_web/live/archive_live_test.exs:208-210`
- Delete: `lib/fae_web/live/archive_live/picker.ex`
- Delete: `test/fae_web/live/archive_live/picker_test.exs`

This is a behavior-preserving refactor of the Archive form. The existing
picker tests in `archive_live_test.exs` are the regression guard.

- [ ] **Step 1: Update the existing remote-picker test's mock to the new shape**

In `test/fae_web/live/archive_live_test.exs`, replace lines 208-210:

```elixir
    stub(DriverMock, :list_prefixes, fn _dest, _prefix ->
      {:ok, %{prefixes: ["Pictures Videos/"], files: []}}
    end)
```

- [ ] **Step 2: Run the two picker tests to confirm they currently pass (pre-refactor baseline)**

Run: `mix test test/fae_web/live/archive_live_test.exs -k "folder picker"`

(If `-k` filtering is unavailable, run the whole file.)
Expected: the local-picker test PASSES; the remote-picker test PASSES (the stub shape change is backward-compatible because `list_remote` reads only `prefixes`).

- [ ] **Step 3: Rewrite the Archive form's picker wiring**

In `lib/fae_web/live/archive_live/form.ex`:

(a) Replace the alias line `alias FaeWeb.ArchiveLive.Picker` with:

```elixir
  alias FaeWeb.PathBrowser
```

(b) In `mount/3`, change the assign from `picker: nil` to `browser: nil`:

```elixir
    socket = assign(socket, destinations: Destinations.list(), browser: nil)
```

(c) Replace the entire "Folder pickers" event block (the `open_local_picker`,
`open_remote_picker`, `picker_navigate`, `picker_up`, `picker_select`,
`picker_close` handlers and all four `handle_async(:picker_load, ...)`
clauses) with:

```elixir
  # ── Folder pickers ────────────────────────────────────────────────

  def handle_event("open_local_picker", _params, socket) do
    browser = %{
      source: {:local, local_start(socket)},
      mode: :pick,
      show_files: false,
      title: "Choose a source folder",
      return_to: :source_path
    }

    {:noreply, assign(socket, :browser, browser)}
  end

  def handle_event("open_remote_picker", _params, socket) do
    case current_destination(socket) do
      nil ->
        {:noreply, put_flash(socket, :error, "Choose a destination first.")}

      dest ->
        browser = %{
          source: {:remote, dest, ""},
          mode: :pick,
          show_files: false,
          title: "Choose a remote folder",
          return_to: :label
        }

        {:noreply, assign(socket, :browser, browser)}
    end
  end

  @impl true
  def handle_info({:path_browser, :selected, return_to, value}, socket) do
    {:noreply, socket |> put_field(return_to, value) |> assign(:browser, nil)}
  end

  def handle_info({:path_browser, :closed}, socket) do
    {:noreply, assign(socket, :browser, nil)}
  end
```

(d) Delete the now-unused private helpers `reload_picker/1`, `load_entries/1`,
and `picker_location/1`. Keep `current_destination/1`, `local_start/1`,
`home/0`, and `put_field/3`.

(e) In `render/1`, replace the whole `<div :if={@picker} class="modal modal-open">…</div>`
block (down to its closing `</div>` before `</Layouts.app>`) with:

```elixir
      <.live_component
        :if={@browser}
        module={PathBrowser}
        id="path-browser"
        source={@browser.source}
        mode={@browser.mode}
        show_files={@browser.show_files}
        title={@browser.title}
        return_to={@browser.return_to}
      />
```

- [ ] **Step 4: Delete the old Picker module and its test**

```bash
git rm lib/fae_web/live/archive_live/picker.ex test/fae_web/live/archive_live/picker_test.exs
```

- [ ] **Step 5: Run the Archive form tests + a clean compile**

Run: `mix compile --warnings-as-errors && mix test test/fae_web/live/archive_live_test.exs`
Expected: PASS — both folder-picker tests still pass against the component, no warnings, no remaining references to `ArchiveLive.Picker`.

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Archive form: use the reusable PathBrowser component"
```

---

## Task 5: Add a view-only remote browser to the Backups job view

**Files:**
- Modify: `lib/fae_web/live/backups_live/job_show.ex`
- Test: `test/fae_web/live/backups_live_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/fae_web/live/backups_live_test.exs` (inside the existing module; uses its `create_destination!/0` and `create_job!/2` helpers and `set_mox_global`):

```elixir
  describe "job show — browse backups" do
    test "opens a view-only remote browser scoped to the job's prefix", %{conn: conn} do
      dest = create_destination!()
      job = create_job!(dest, %{prefix: "Family", slug: "daily-db"})

      # Expect a listing relative to the destination prefix at
      # "<job.prefix>/<job.slug>/", i.e. "Family/daily-db/".
      stub(DriverMock, :list_prefixes, fn _dest, prefix ->
        assert prefix == "Family/daily-db/"

        {:ok,
         %{
           prefixes: [],
           files: [
             %{
               key: "Family/daily-db/2026-05-01.tar.gz",
               size: 2048,
               last_modified: ~U[2026-05-01 12:00:00Z]
             }
           ]
         }}
      end)

      {:ok, view, _html} = live(conn, ~p"/backups/#{job.id}")

      view |> element("button", "Browse backups") |> render_click()
      html = render_async(view)

      assert html =~ "2026-05-01.tar.gz"
      assert html =~ "2.0 KiB"
      # View-only: no selection affordance.
      refute html =~ "Use this folder"
    end
  end
```

(`create_job!/2` already accepts an overrides map; pass `prefix` and `slug`
through it. The destination has no `path_prefix`, so the browse prefix is
exactly `Family/daily-db/`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/fae_web/live/backups_live_test.exs -k "browse backups"`
Expected: FAIL — there is no "Browse backups" button yet.

- [ ] **Step 3: Wire the browser into JobShow**

In `lib/fae_web/live/backups_live/job_show.ex`:

(a) Add the alias near the top:

```elixir
  alias FaeWeb.PathBrowser
```

(b) In `mount/3`, add `|> assign(:browser, nil)` to the socket pipeline (the
existing pipeline that assigns `:page_title`, `:job`, `:runs`).

(c) Add the open handler and the `:closed` info handler. Place the
`handle_info({:path_browser, :closed}, …)` clause **before** the existing
`handle_info(_, socket)` catch-all:

```elixir
  @impl true
  def handle_event("run_now", %{"id" => id}, socket) do
    _ = Backups.run_now(id)
    {:noreply, refresh(socket)}
  end

  def handle_event("open_browser", _params, socket) do
    job = socket.assigns.job
    start_rel = [job.prefix, job.slug] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("/")

    browser = %{
      source: {:remote, job.destination, start_rel},
      mode: :view,
      show_files: true,
      title: "Backups in #{job.name}",
      return_to: nil
    }

    {:noreply, assign(socket, :browser, browser)}
  end
```

And add the `:closed` clause above `handle_info(_, socket)`:

```elixir
  def handle_info({:path_browser, :closed}, socket), do: {:noreply, assign(socket, :browser, nil)}
  def handle_info(_, socket), do: {:noreply, socket}
```

(d) In `render/1`, add a "Browse backups" button in the header button row
(next to Edit / Run now), shown only when a destination is loaded:

```elixir
            <button
              :if={@job.destination}
              type="button"
              phx-click="open_browser"
              class="btn btn-sm btn-ghost"
            >
              Browse backups
            </button>
```

(e) At the end of `render/1`, before the closing `</Layouts.app>`, add:

```elixir
      <.live_component
        :if={@browser}
        module={PathBrowser}
        id="path-browser"
        source={@browser.source}
        mode={@browser.mode}
        show_files={@browser.show_files}
        title={@browser.title}
        return_to={@browser.return_to}
      />
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/fae_web/live/backups_live_test.exs`
Expected: PASS (new test plus the existing ones).

- [ ] **Step 5: Full suite + clean compile**

Run: `mix compile --warnings-as-errors && mix test`
Expected: PASS, no warnings.

- [ ] **Step 6: Commit**

```bash
git add lib/fae_web/live/backups_live/job_show.ex test/fae_web/live/backups_live_test.exs
git commit -m "Backups job view: browse a job's backups on the remote destination"
```

---

## Self-Review notes

- **Spec coverage:** reusable component (Task 3) ✓; pick + view modes (Task 3 render) ✓; per-use file visibility via `show_files` (Tasks 2/3) ✓; file name+size+date (Tasks 1/3) ✓; backups start at `<job.prefix>/<job.slug>` (Task 5) ✓; Archive form rewired, Picker deleted (Task 4) ✓; testing per spec (Tasks 1,2,4,5) ✓.
- **Type consistency:** `list_prefixes` returns `%{prefixes:, files:}` (Task 1) and `Source.list/2` / `relativize/3` consume `files` (Task 2); component assigns `kind/dest/loc/folders/files/loading/error/initialized?` are set in `update/2` and read in `render/1` and `handle_*` (Task 3); the browser spec map keys (`source/mode/show_files/title/return_to`) match the `<.live_component>` attrs in Tasks 4 and 5.
- **Out of scope (unchanged):** acting on files (download/delete/restore); a formal source behaviour; JobShow's existing `mount` query.
```
