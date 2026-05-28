defmodule FaeWeb.ArchiveLiveTest do
  use FaeWeb.ConnCase, async: false
  use Oban.Testing, repo: Fae.Repo

  import Mox
  import Phoenix.LiveViewTest

  alias Fae.Archive
  alias Fae.Archive.Runs
  alias Fae.Storage.Destinations
  alias Fae.Storage.Drivers.DriverMock

  setup :set_mox_global
  setup :verify_on_exit!

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:fae, :storage_drivers, %{"s3" => DriverMock})
    on_exit(fn -> Application.delete_env(:fae, :storage_drivers) end)

    File.write!(Path.join(tmp_dir, "a.jpg"), "aaaa")

    {:ok, dest} =
      Destinations.create(%{
        name: "Dest #{System.unique_integer([:positive])}",
        driver: "s3",
        endpoint_url: "https://example.com",
        region: "us",
        bucket: "b",
        access_key_id: "k",
        secret_access_key: "s"
      })

    {:ok, dest: dest, source: tmp_dir}
  end

  test "index shows the empty state", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/archive")
    assert html =~ "No archives yet"
  end

  test "new form rejects a non-existent source path", %{conn: conn, dest: dest} do
    {:ok, view, _html} = live(conn, ~p"/archive/new")

    html =
      view
      |> form("form",
        run: %{name: "Cam", source_path: "/no/such/dir", label: "X", destination_id: dest.id}
      )
      |> render_change()

    assert html =~ "is not an existing directory"
  end

  test "creating an archive runs it inline and lands on a completed run", %{
    conn: conn,
    dest: dest,
    source: source
  } do
    stub(DriverMock, :put_stream, fn _dest, _key, path, _opts ->
      {:ok, %{byte_size: File.stat!(path).size, sha256: "sha", etag: ~s("e")}}
    end)

    {:ok, view, _html} = live(conn, ~p"/archive/new")

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> form("form",
               run: %{
                 name: "Camera Backup",
                 source_path: source,
                 label: "Pics",
                 destination_id: dest.id
               }
             )
             |> render_submit()

    assert to =~ ~r"^/archive/"

    {:ok, _show, html} = live(conn, to)
    assert html =~ "completed"
    assert html =~ "Camera Backup"
    assert html =~ "a.jpg"
  end

  test "Sync now on the show page re-runs the archive", %{conn: conn, dest: dest, source: source} do
    stub(DriverMock, :put_stream, fn _dest, _key, path, _opts ->
      {:ok, %{byte_size: File.stat!(path).size, sha256: "s", etag: "e"}}
    end)

    {:ok, run} =
      Archive.start_archive(%{
        name: "Camera Backup",
        source_path: source,
        label: "Pics",
        destination_id: dest.id
      })

    {:ok, view, _html} = live(conn, ~p"/archive/#{run.id}")
    html = view |> element("button", "Sync now") |> render_click()
    assert html =~ "completed"
  end

  test "Delete on the show page removes the archive", %{conn: conn, dest: dest, source: source} do
    stub(DriverMock, :put_stream, fn _dest, _key, path, _opts ->
      {:ok, %{byte_size: File.stat!(path).size, sha256: "s", etag: "e"}}
    end)

    {:ok, run} =
      Archive.start_archive(%{
        name: "Camera Backup",
        source_path: source,
        label: "Pics",
        destination_id: dest.id
      })

    {:ok, view, _html} = live(conn, ~p"/archive/#{run.id}")

    assert {:error, {:live_redirect, %{to: "/archive"}}} =
             view |> element("button", "Delete") |> render_click()

    assert Runs.get(run.id) == nil
  end

  test "Rename on the show page updates the name in place", %{
    conn: conn,
    dest: dest,
    source: source
  } do
    stub(DriverMock, :put_stream, fn _dest, _key, path, _opts ->
      {:ok, %{byte_size: File.stat!(path).size, sha256: "s", etag: "e"}}
    end)

    {:ok, run} =
      Archive.start_archive(%{
        name: "Camera Backup",
        source_path: source,
        label: "Pics",
        destination_id: dest.id
      })

    {:ok, view, _html} = live(conn, ~p"/archive/#{run.id}")
    view |> element("button", "Rename") |> render_click()

    html = view |> form("form", run: %{name: "Family Photos"}) |> render_submit()
    assert html =~ "Family Photos"
    assert Runs.get(run.id).name == "Family Photos"
  end

  test "Reconfigure replaces the archive and lands on the new one", %{
    conn: conn,
    dest: dest,
    source: source
  } do
    stub(DriverMock, :put_stream, fn _dest, _key, path, _opts ->
      {:ok, %{byte_size: File.stat!(path).size, sha256: "s", etag: "e"}}
    end)

    {:ok, old} =
      Archive.start_archive(%{
        name: "Camera Backup",
        source_path: source,
        label: "Pics",
        destination_id: dest.id
      })

    {:ok, view, _html} = live(conn, ~p"/archive/#{old.id}/edit")

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> form("form",
               run: %{
                 name: "Camera Backup",
                 source_path: source,
                 label: "Videos",
                 destination_id: dest.id
               }
             )
             |> render_submit()

    assert to =~ ~r"^/archive/"
    refute to == "/archive/#{old.id}"
    assert Runs.get(old.id) == nil
  end

  test "the local folder picker browses and fills the Source field", %{conn: conn, source: source} do
    File.mkdir_p!(Path.join(source, "sub"))

    {:ok, view, _html} = live(conn, ~p"/archive/new")
    # Point the source at the tmp dir so the picker starts there.
    view |> form("form", run: %{source_path: source}) |> render_change()

    view |> element("button[title='Browse local folders']") |> render_click()
    assert render_async(view) =~ "sub"

    view |> element("button[phx-value-name='sub']") |> render_click()
    render_async(view)
    view |> element("button", "Use this folder") |> render_click()

    assert render(view) =~ ~s(value="#{Path.join(source, "sub")}")
  end

  test "the remote folder picker browses the destination and fills the Remote folder", %{
    conn: conn,
    dest: dest
  } do
    stub(DriverMock, :list_prefixes, fn _dest, _prefix ->
      {:ok, %{prefixes: ["Pictures Videos/"], files: []}}
    end)

    {:ok, view, _html} = live(conn, ~p"/archive/new")
    view |> form("form", run: %{destination_id: dest.id}) |> render_change()

    view |> element("button[title='Browse the destination']") |> render_click()
    assert render_async(view) =~ "Pictures Videos"

    view |> element("button[phx-value-name='Pictures Videos']") |> render_click()
    render_async(view)
    view |> element("button", "Use this folder") |> render_click()

    assert render(view) =~ ~s(value="Pictures Videos")
  end

  describe "Quick Archive" do
    defp stub_uploads do
      stub(DriverMock, :put_stream, fn _dest, _key, path, _opts ->
        {:ok, %{byte_size: File.stat!(path).size, sha256: "sha", etag: ~s("e")}}
      end)
    end

    test "index links to the Quick Archive form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/archive")
      assert view |> element("a", "Quick Archive") |> has_element?()
    end

    test "the quick form rejects a non-existent source path", %{conn: conn, dest: dest} do
      {:ok, view, _html} = live(conn, ~p"/archive/quick/new")

      html =
        view
        |> form("form",
          quick: %{name: "Cam", source_path: "/no/such/dir", destination_id: dest.id}
        )
        |> render_change()

      assert html =~ "is not an existing directory"
    end

    test "previews the dated folder path as the operator types", %{conn: conn} do
      {:ok, dest} =
        Destinations.create(%{
          name: "Dest #{System.unique_integer([:positive])}",
          driver: "s3",
          endpoint_url: "https://example.com",
          region: "us",
          bucket: "b",
          path_prefix: "Family Backups",
          quick_archive_prefix: "archive",
          access_key_id: "k",
          secret_access_key: "s"
        })

      {:ok, view, _html} = live(conn, ~p"/archive/quick/new")

      html =
        view
        |> form("form", quick: %{name: "My Camera Backup", destination_id: dest.id})
        |> render_change()

      year = Date.utc_today().year
      assert html =~ "Family Backups/archive/#{year}/"
      assert html =~ "my-camera-backup"
    end

    test "creating a quick archive runs it inline and lands on a completed, dated run", %{
      conn: conn,
      dest: dest,
      source: source
    } do
      stub_uploads()

      {:ok, view, _html} = live(conn, ~p"/archive/quick/new")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("form",
                 quick: %{name: "My Camera Backup", source_path: source, destination_id: dest.id}
               )
               |> render_submit()

      "/archive/" <> id = to
      run = Runs.get(id)
      assert run.kind == "quick"
      assert run.name == "My Camera Backup"

      today = Date.to_iso8601(Date.utc_today())
      assert run.label =~ ~r"/#{today}-my-camera-backup$"
      assert Runs.get(id).status == "completed"

      {:ok, show, _html} = live(conn, to)
      assert show |> element("h2", "My Camera Backup") |> has_element?()
    end

    test "rejects a name with nothing slug-worthy", %{conn: conn, dest: dest, source: source} do
      {:ok, view, _html} = live(conn, ~p"/archive/quick/new")

      html =
        view
        |> form("form", quick: %{name: "!!! ???", source_path: source, destination_id: dest.id})
        |> render_submit()

      assert html =~ "letter or number"
    end

    test "rejects a same-day collision and links to the existing run", %{
      conn: conn,
      dest: dest,
      source: source
    } do
      stub_uploads()

      {:ok, existing} =
        Archive.start_quick_archive(%{
          "name" => "My Camera Backup",
          "source_path" => source,
          "destination_id" => dest.id
        })

      {:ok, view, _html} = live(conn, ~p"/archive/quick/new")

      html =
        view
        |> form("form",
          quick: %{name: "My Camera Backup", source_path: source, destination_id: dest.id}
        )
        |> render_submit()

      assert html =~ "already"
      assert html =~ ~p"/archive/#{existing.id}"
    end

    test "index badges quick runs; show page action set differs from standard", %{
      conn: conn,
      dest: dest,
      source: source
    } do
      stub_uploads()

      {:ok, run} =
        Archive.start_quick_archive(%{
          "name" => "My Camera Backup",
          "source_path" => source,
          "destination_id" => dest.id
        })

      {:ok, index, _html} = live(conn, ~p"/archive")
      assert index |> element("#run-#{run.id} .badge", "quick") |> has_element?()

      {:ok, show, _html} = live(conn, ~p"/archive/#{run.id}")
      refute show |> element("button", "Sync now") |> has_element?()
      refute show |> element("a", "Reconfigure") |> has_element?()
      assert show |> element("button", "Retry") |> has_element?()
      assert show |> element("button", "Rename") |> has_element?()
    end
  end
end
