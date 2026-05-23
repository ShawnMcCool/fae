defmodule Fae.Archive.ArchiveWorkerTest do
  use Fae.DataCase, async: false
  use Oban.Testing, repo: Fae.Repo

  import Mox

  alias Fae.Archive.ArchiveWorker
  alias Fae.Archive.Items
  alias Fae.Archive.Runs
  alias Fae.Storage.Destinations
  alias Fae.Storage.Drivers.DriverMock

  setup :set_mox_global
  setup :verify_on_exit!

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:fae, :storage_drivers, %{"s3" => DriverMock})
    on_exit(fn -> Application.delete_env(:fae, :storage_drivers) end)

    File.mkdir_p!(Path.join(tmp_dir, "sub"))
    File.write!(Path.join(tmp_dir, "a.jpg"), "aaaa")
    File.write!(Path.join(tmp_dir, "b.jpg"), "bb")
    File.write!(Path.join(tmp_dir, "sub/c.jpg"), "cccccc")

    {:ok, dest} =
      Destinations.create(%{
        name: "Dest #{System.unique_integer([:positive])}",
        driver: "s3",
        endpoint_url: "https://example.com",
        region: "us",
        bucket: "b",
        path_prefix: "Family",
        access_key_id: "k",
        secret_access_key: "s"
      })

    {:ok, run} =
      Runs.create(%{name: "Cam", source_path: tmp_dir, label: "Pics", destination_id: dest.id})

    {:ok, run: run, dest: dest, source: tmp_dir}
  end

  defp ok_upload do
    fn _dest, _key, path, _opts ->
      {:ok,
       %{byte_size: File.stat!(path).size, sha256: "sha-#{Path.basename(path)}", etag: ~s("e")}}
    end
  end

  test "scans, uploads every file, and finalizes the run completed", %{run: run} do
    stub(DriverMock, :put_stream, ok_upload())

    assert :ok = perform_job(ArchiveWorker, %{"run_id" => run.id})

    run = Runs.get(run.id)
    assert run.status == "completed"
    assert run.total_files == 3
    assert run.total_bytes == 12
    assert run.uploaded_files == 3
    assert run.failed_files == 0

    items = Items.list_for_run(run.id)
    assert length(items) == 3
    assert Enum.all?(items, &(&1.status == "uploaded"))
    assert Enum.all?(items, &(&1.sha256 != nil and &1.uploaded_at != nil))
  end

  test "builds object keys as prefix/label/relative-path", %{run: run} do
    parent = self()

    stub(DriverMock, :put_stream, fn _dest, key, path, _opts ->
      send(parent, {:key, key})
      {:ok, %{byte_size: File.stat!(path).size, sha256: "s", etag: "e"}}
    end)

    perform_job(ArchiveWorker, %{"run_id" => run.id})

    assert_receive {:key, "Family/Pics/a.jpg"}
    assert_receive {:key, "Family/Pics/b.jpg"}
    assert_receive {:key, "Family/Pics/sub/c.jpg"}
  end

  test "records per-file failures and marks the run partial", %{run: run} do
    stub(DriverMock, :put_stream, fn _dest, key, path, _opts ->
      if String.ends_with?(key, "b.jpg") do
        {:error, :boom}
      else
        {:ok, %{byte_size: File.stat!(path).size, sha256: "s", etag: "e"}}
      end
    end)

    perform_job(ArchiveWorker, %{"run_id" => run.id})

    run = Runs.get(run.id)
    assert run.status == "partial"
    assert run.uploaded_files == 2
    assert run.failed_files == 1

    failed = Items.list_for_run(run.id) |> Enum.filter(&(&1.status == "failed"))
    assert [%{relative_path: "b.jpg", error_message: message}] = failed
    assert message =~ "boom"
  end

  test "resume uploads only pending items, skipping already-uploaded ones", %{run: run} do
    # Simulate a prior run that already uploaded a.jpg.
    Items.insert_scanned(run.id, [
      %{relative_path: "a.jpg", object_key: "Family/Pics/a.jpg", byte_size: 4}
    ])

    [already] = Items.pending_for_run(run.id) |> Enum.filter(&(&1.relative_path == "a.jpg"))
    {:ok, _} = Items.record_uploaded(already, %{byte_size: 4, sha256: "old", etag: "old"})

    parent = self()

    stub(DriverMock, :put_stream, fn _dest, key, path, _opts ->
      send(parent, {:uploaded, key})
      {:ok, %{byte_size: File.stat!(path).size, sha256: "s", etag: "e"}}
    end)

    assert :ok = perform_job(ArchiveWorker, %{"run_id" => run.id})

    assert_receive {:uploaded, "Family/Pics/b.jpg"}
    assert_receive {:uploaded, "Family/Pics/sub/c.jpg"}
    refute_received {:uploaded, "Family/Pics/a.jpg"}

    assert Runs.get(run.id).status == "completed"
    a_item = Items.list_for_run(run.id) |> Enum.find(&(&1.relative_path == "a.jpg"))
    assert a_item.sha256 == "old"
  end

  test "start_archive runs the whole archive inline", %{dest: dest, source: source} do
    stub(DriverMock, :put_stream, ok_upload())

    assert {:ok, run} =
             Fae.Archive.start_archive(%{
               name: "Cam",
               source_path: source,
               label: "Pics",
               destination_id: dest.id
             })

    assert Runs.get(run.id).status == "completed"
  end

  test "sync re-runs failed items to success", %{run: run} do
    stub(DriverMock, :put_stream, fn _dest, _key, _path, _opts -> {:error, :down} end)
    perform_job(ArchiveWorker, %{"run_id" => run.id})
    assert Runs.get(run.id).status == "partial"

    stub(DriverMock, :put_stream, ok_upload())
    assert {:ok, _job} = Fae.Archive.sync(run.id)

    run = Runs.get(run.id)
    assert run.status == "completed"
    assert run.failed_files == 0
    assert Enum.all?(Items.list_for_run(run.id), &(&1.status == "uploaded"))
  end

  test "sync after adding a file uploads only the new file (manual mirror)", %{
    run: run,
    source: source
  } do
    parent = self()

    stub(DriverMock, :put_stream, fn _dest, key, path, _opts ->
      send(parent, {:uploaded, key})
      {:ok, %{byte_size: File.stat!(path).size, sha256: "s", etag: "e"}}
    end)

    # First sync uploads the three setup files.
    perform_job(ArchiveWorker, %{"run_id" => run.id})
    assert_receive {:uploaded, "Family/Pics/a.jpg"}
    assert_receive {:uploaded, "Family/Pics/b.jpg"}
    assert_receive {:uploaded, "Family/Pics/sub/c.jpg"}

    # Drop a new file in, then Sync now.
    new_path = Path.join(source, "2024/new.jpg")
    File.mkdir_p!(Path.dirname(new_path))
    File.write!(new_path, "new!")
    assert {:ok, _job} = Fae.Archive.sync(run.id)

    # Only the new file is uploaded; the originals are skipped.
    assert_receive {:uploaded, "Family/Pics/2024/new.jpg"}
    refute_received {:uploaded, "Family/Pics/a.jpg"}
    refute_received {:uploaded, "Family/Pics/b.jpg"}

    run = Runs.get(run.id)
    assert run.status == "completed"
    assert run.total_files == 4
    assert Enum.all?(Items.list_for_run(run.id), &(&1.status == "uploaded"))
  end
end
