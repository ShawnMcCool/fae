defmodule Fae.Archive.RunsTest do
  use Fae.DataCase, async: false

  alias Fae.Archive.Runs
  alias Fae.Storage.Destination
  alias Fae.Storage.Destinations
  alias Fae.Topics

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

    {:ok, dest: dest, source: tmp_dir}
  end

  test "create/1 persists a pending run and broadcasts", %{dest: dest, source: source} do
    :ok = Phoenix.PubSub.subscribe(Fae.PubSub, Topics.archive_runs())

    assert {:ok, run} =
             Runs.create(%{source_path: source, label: "Pics", destination_id: dest.id})

    assert run.status == "pending"
    assert_receive {:run_changed, run_id}
    assert run_id == run.id
  end

  test "lifecycle: scanning -> uploading -> finalize completed", %{dest: dest, source: source} do
    {:ok, run} = Runs.create(%{source_path: source, destination_id: dest.id})

    {:ok, run} = Runs.mark_scanning(run)
    assert run.status == "scanning"
    assert run.started_at

    {:ok, run} = Runs.mark_uploading(run, 10, 1000)
    assert run.status == "uploading"
    assert run.total_files == 10
    assert run.total_bytes == 1000

    {:ok, run} = Runs.finalize(run, %{uploaded_files: 10, uploaded_bytes: 1000, failed_files: 0})
    assert run.status == "completed"
    assert run.finished_at
  end

  test "finalize with failures marks the run partial", %{dest: dest, source: source} do
    {:ok, run} = Runs.create(%{source_path: source, destination_id: dest.id})
    {:ok, run} = Runs.finalize(run, %{uploaded_files: 8, uploaded_bytes: 800, failed_files: 2})
    assert run.status == "partial"
    assert run.failed_files == 2
  end

  test "mark_failed records the error and broadcasts finished", %{dest: dest, source: source} do
    :ok = Phoenix.PubSub.subscribe(Fae.PubSub, Topics.archive_runs())
    {:ok, run} = Runs.create(%{source_path: source, destination_id: dest.id})

    {:ok, run} = Runs.mark_failed(run, "boom")
    assert run.status == "failed"
    assert run.error_message == "boom"
    assert_receive {:run_finished, _id, :failed}
  end

  test "list/0 returns runs newest first with destination preloaded", %{
    dest: dest,
    source: source
  } do
    {:ok, _a} = Runs.create(%{source_path: source, destination_id: dest.id})
    {:ok, _b} = Runs.create(%{source_path: source, destination_id: dest.id})

    runs = Runs.list()
    assert length(runs) == 2
    assert %Destination{} = hd(runs).destination
  end
end
