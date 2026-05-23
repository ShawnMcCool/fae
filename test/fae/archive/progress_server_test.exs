defmodule Fae.Archive.ProgressServerTest do
  # Exercises the application-wide ProgressServer. async: false because
  # it is a shared global process and we assert on PubSub broadcasts.
  use ExUnit.Case, async: false

  alias Fae.Archive.ProgressServer
  alias Fae.Topics

  test "tracks uploaded and failed counts via the public API" do
    run_id = Ecto.UUID.generate()
    ProgressServer.start_run(run_id, 3, 600)
    ProgressServer.record_uploaded(run_id, 100)
    ProgressServer.record_uploaded(run_id, 200)
    ProgressServer.record_failed(run_id)

    snap = ProgressServer.snapshot(run_id)
    assert snap.total_files == 3
    assert snap.total_bytes == 600
    assert snap.uploaded_files == 2
    assert snap.uploaded_bytes == 300
    assert snap.failed_files == 1
    assert is_integer(snap.elapsed_ms)
    refute Map.has_key?(snap, :started_monotonic_ms)

    ProgressServer.finish_run(run_id)
    assert ProgressServer.snapshot(run_id) == nil
  end

  test "seeds already-completed tallies on resume" do
    run_id = Ecto.UUID.generate()

    ProgressServer.start_run(run_id, 5, 1000, %{
      uploaded_files: 2,
      uploaded_bytes: 400,
      failed_files: 1
    })

    snap = ProgressServer.snapshot(run_id)
    assert snap.uploaded_files == 2
    assert snap.uploaded_bytes == 400
    assert snap.failed_files == 1

    ProgressServer.finish_run(run_id)
  end

  test "broadcasts a final snapshot on finish_run" do
    :ok = Phoenix.PubSub.subscribe(Fae.PubSub, Topics.archive_progress())
    run_id = Ecto.UUID.generate()

    ProgressServer.start_run(run_id, 1, 10)
    ProgressServer.record_uploaded(run_id, 10)
    ProgressServer.finish_run(run_id)

    snap = drain_until_uploaded(run_id, 1)
    assert snap.uploaded_bytes == 10
  end

  test "broadcasts periodic snapshots while a run is active" do
    :ok = Phoenix.PubSub.subscribe(Fae.PubSub, Topics.archive_progress())
    run_id = Ecto.UUID.generate()

    ProgressServer.start_run(run_id, 2, 20)
    assert_receive {:archive_progress, ^run_id, _snap}, 1000

    ProgressServer.finish_run(run_id)
  end

  # Ignore any earlier ticks and return the snapshot reflecting the
  # expected uploaded count.
  defp drain_until_uploaded(run_id, expected) do
    receive do
      {:archive_progress, ^run_id, %{uploaded_files: ^expected} = snap} -> snap
      {:archive_progress, ^run_id, _other} -> drain_until_uploaded(run_id, expected)
    after
      1000 -> flunk("no progress broadcast with uploaded_files=#{expected}")
    end
  end
end
