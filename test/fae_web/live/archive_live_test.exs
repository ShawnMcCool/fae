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
end
