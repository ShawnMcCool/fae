defmodule Fae.StatusTest do
  # Not async: snapshot/0 reads global, non-sandboxed process state — the
  # SystemStatus GenServer and the SelfUpdate/UpdateChecker :persistent_term
  # cache. Running async would interleave with tests that assert on that
  # shared state (e.g. SelfUpdate.StorageTest).
  use Fae.DataCase, async: false

  alias Fae.Backups.{Jobs, Run, Runs}
  alias Fae.Status
  alias Fae.Storage.Destinations

  describe "snapshot/0" do
    test "gathers the operational input map the dashboard and status contract consume" do
      snapshot = Status.snapshot()

      assert is_list(snapshot.jobs)
      assert is_map(snapshot.last_runs)
      assert is_list(snapshot.recent_runs)
      assert is_list(snapshot.destinations)
      assert is_binary(snapshot.version)
      assert is_atom(snapshot.self_update_phase)
      assert %DateTime{} = snapshot.now
      assert %DateTime{} = snapshot.system.boot_at
      assert is_integer(snapshot.system.uptime_seconds)
      assert Map.has_key?(snapshot, :latest_release)
      assert Map.has_key?(snapshot.dotfiles, :config)
      assert Map.has_key?(snapshot.dotfiles, :tracked_count)
      assert Map.has_key?(snapshot.dotfiles, :last_run)
    end

    test "includes enabled jobs and their last run, keyed by job id" do
      destination = create_destination!()
      job = create_job!(destination)
      {:ok, %Run{} = run} = Runs.start(job.id, ~U[2026-05-30 06:00:00.000000Z])

      snapshot = Status.snapshot()

      assert Enum.any?(snapshot.jobs, &(&1.id == job.id))
      assert %Run{id: run_id} = snapshot.last_runs[job.id]
      assert run_id == run.id
      assert Enum.any?(snapshot.recent_runs, &(&1.id == run.id))
    end

    test "maps a job with no runs to a nil last run" do
      destination = create_destination!()
      job = create_job!(destination)

      snapshot = Status.snapshot()

      assert Map.fetch!(snapshot.last_runs, job.id) == nil
    end
  end

  defp create_destination!(overrides \\ []) do
    attrs =
      Map.merge(
        %{
          name: "Test Dest #{System.unique_integer([:positive])}",
          driver: "s3",
          endpoint_url: "https://example.com",
          region: "us",
          bucket: "test-bucket",
          access_key_id: "k",
          secret_access_key: "s"
        },
        Map.new(overrides)
      )

    {:ok, destination} = Destinations.create(attrs)
    destination
  end

  defp create_job!(destination, overrides \\ []) do
    attrs =
      Map.merge(
        %{
          name: "Daily Fae DB",
          slug: "daily-fae-db-#{System.unique_integer([:positive])}",
          source_kind: "file",
          source_path: "/tmp/fae.db",
          destination_id: destination.id,
          package_format: "as_is",
          recurrence_kind: "daily",
          time_of_day: "03:00",
          retention_strategy: "keep_last_n",
          retention_params: %{"n" => 7}
        },
        Map.new(overrides)
      )

    {:ok, job} = Jobs.create(attrs)
    job
  end
end
