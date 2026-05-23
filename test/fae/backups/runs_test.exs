defmodule Fae.Backups.RunsTest do
  use Fae.DataCase, async: false

  alias Fae.Backups.{Jobs, Runs}
  alias Fae.Storage.Destinations

  setup do
    {:ok, destination} =
      Destinations.create(%{
        name: "Test",
        driver: "s3",
        endpoint_url: "https://example.com",
        region: "us",
        bucket: "b",
        access_key_id: "k",
        secret_access_key: "s"
      })

    {:ok, job} =
      Jobs.create(%{
        name: "Daily",
        slug: "daily",
        source_kind: "file",
        source_path: "/tmp/a.txt",
        destination_id: destination.id,
        package_format: "as_is",
        recurrence_kind: "daily",
        time_of_day: "03:00",
        retention_strategy: "keep_last_n",
        retention_params: %{"n" => 5}
      })

    %{job: job}
  end

  test "start/2 inserts a running row", %{job: job} do
    now = DateTime.utc_now()
    assert {:ok, run} = Runs.start(job.id, now)
    assert run.status == "running"
    assert run.job_id == job.id
    assert DateTime.compare(run.started_at, now) == :eq
  end

  test "finish/2 transitions to success", %{job: job} do
    {:ok, run} = Runs.start(job.id, DateTime.utc_now())
    finished_at = DateTime.utc_now()

    assert {:ok, finished} =
             Runs.finish(run, %{
               finished_at: finished_at,
               status: "success",
               object_key: "k",
               byte_size: 12_345,
               sha256: "deadbeef"
             })

    assert finished.status == "success"
    assert finished.object_key == "k"
    assert finished.byte_size == 12_345
    assert finished.sha256 == "deadbeef"
  end

  test "record_skipped/3 inserts a terminal skipped row", %{job: job} do
    now = DateTime.utc_now()
    assert {:ok, run} = Runs.record_skipped(job.id, :overlap, now)
    assert run.status == "skipped"
    assert run.error_message =~ "overlap"
    assert run.finished_at != nil
  end

  test "list_recent/2 returns most-recent first", %{job: job} do
    now = DateTime.utc_now()

    for offset <- 0..3 do
      ts = DateTime.add(now, -offset, :second)
      Runs.start(job.id, ts)
    end

    runs = Runs.list_recent(job.id, 10)
    assert length(runs) == 4

    started_ats = Enum.map(runs, & &1.started_at)
    assert started_ats == Enum.sort(started_ats, {:desc, DateTime})
  end

  test "last/1 returns nil when no runs", %{job: job} do
    assert Runs.last(job.id) == nil
  end

  test "last/1 returns the most recent run", %{job: job} do
    now = DateTime.utc_now()
    {:ok, _old} = Runs.start(job.id, DateTime.add(now, -3600, :second))
    {:ok, recent} = Runs.start(job.id, now)
    assert Runs.last(job.id).id == recent.id
  end
end
