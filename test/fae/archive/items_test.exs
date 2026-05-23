defmodule Fae.Archive.ItemsTest do
  use Fae.DataCase, async: false

  alias Fae.Archive.Item
  alias Fae.Archive.Items
  alias Fae.Archive.Runs
  alias Fae.Storage.Destinations

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
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

    {:ok, run} = Runs.create(%{name: "T", source_path: tmp_dir, destination_id: dest.id})
    {:ok, run: run}
  end

  test "insert_scanned inserts pending items and is idempotent", %{run: run} do
    entries = [
      %{relative_path: "a.jpg", object_key: "k/a.jpg", byte_size: 10},
      %{relative_path: "b.jpg", object_key: "k/b.jpg", byte_size: 20}
    ]

    assert Items.insert_scanned(run.id, entries) == 2
    # Re-scan (resume): no duplicates created.
    Items.insert_scanned(run.id, entries)

    items = Items.list_for_run(run.id)
    assert length(items) == 2
    assert Enum.all?(items, &(&1.status == "pending"))
  end

  test "record_uploaded sets the durable record and clears it from pending", %{run: run} do
    Items.insert_scanned(run.id, [%{relative_path: "a.jpg", object_key: "k/a.jpg", byte_size: 10}])

    [item] = Items.pending_for_run(run.id)

    {:ok, updated} = Items.record_uploaded(item, %{byte_size: 10, sha256: "abc", etag: ~s("e")})
    assert updated.status == "uploaded"
    assert updated.sha256 == "abc"
    assert updated.etag == ~s("e")
    assert updated.uploaded_at
    assert updated.attempts == 1
    assert Items.pending_for_run(run.id) == []
  end

  test "record_failed sets status and message", %{run: run} do
    Items.insert_scanned(run.id, [%{relative_path: "a.jpg", object_key: "k/a.jpg", byte_size: 10}])

    [item] = Items.pending_for_run(run.id)

    {:ok, updated} = Items.record_failed(item, "nope")
    assert updated.status == "failed"
    assert updated.error_message == "nope"
    assert updated.attempts == 1
  end

  test "reset_failed returns failed items to pending", %{run: run} do
    Items.insert_scanned(run.id, [%{relative_path: "a.jpg", object_key: "k/a.jpg", byte_size: 10}])

    [item] = Items.pending_for_run(run.id)
    {:ok, _} = Items.record_failed(item, "nope")

    assert Items.reset_failed(run.id) == 1
    assert [%Item{status: "pending"}] = Items.pending_for_run(run.id)
  end

  test "counts_for_run aggregates uploaded and failed tallies", %{run: run} do
    Items.insert_scanned(run.id, [
      %{relative_path: "a", object_key: "k/a", byte_size: 10},
      %{relative_path: "b", object_key: "k/b", byte_size: 20},
      %{relative_path: "c", object_key: "k/c", byte_size: 30}
    ])

    [a, b, c] = Items.pending_for_run(run.id)
    {:ok, _} = Items.record_uploaded(a, %{byte_size: 10, sha256: "x", etag: "y"})
    {:ok, _} = Items.record_uploaded(b, %{byte_size: 20, sha256: "x", etag: "y"})
    {:ok, _} = Items.record_failed(c, "no")

    assert Items.counts_for_run(run.id) == %{
             uploaded_files: 2,
             uploaded_bytes: 30,
             failed_files: 1
           }
  end
end
