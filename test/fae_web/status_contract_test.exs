defmodule FaeWeb.StatusContractTest do
  use ExUnit.Case, async: true

  alias Fae.Backups.{Job, Run}
  alias Fae.Dotfiles.Config
  alias FaeWeb.StatusContract

  @now ~U[2026-05-30 12:00:00.000000Z]

  defp base_input(overrides \\ %{}) do
    Map.merge(
      %{
        jobs: [],
        last_runs: %{},
        recent_runs: [],
        destinations: [],
        version: "0.7.0",
        latest_release: nil,
        self_update_phase: :idle,
        self_update_error: nil,
        system: %{boot_at: ~U[2026-05-29 08:00:00.000000Z], uptime_seconds: 101_696},
        now: @now,
        dotfiles: %{
          config: %Config{enabled: true, last_push_ok: true, last_backup_at: nil},
          tracked_count: 0,
          last_run: nil
        }
      },
      Map.new(overrides)
    )
  end

  defp job(overrides) do
    struct(
      %Job{
        name: "Family Photos",
        enabled: true,
        recurrence_kind: "daily",
        time_of_day: "03:00"
      },
      overrides
    )
  end

  describe "build/1 top-level shape" do
    test "produces the schema, generated_at, and all top-level keys for a healthy empty system" do
      result = StatusContract.build(base_input())

      assert result.schema == 1
      assert result.generated_at == "2026-05-30T12:00:00Z"
      assert result.health == %{level: "healthy", reason: nil}

      assert result.system == %{
               version: "0.7.0",
               booted_at: "2026-05-29T08:00:00Z",
               uptime_seconds: 101_696,
               update: %{state: "idle", version: nil, published_at: nil}
             }

      assert result.backups == %{
               enabled_count: 0,
               failing_count: 0,
               next_fire_at: nil,
               jobs: []
             }

      assert result.activity == []

      assert result.dotfiles == %{
               enabled: true,
               last_backup_at: nil,
               last_push_ok: true,
               tracked_count: 0
             }
    end

    test "truncates timestamps to whole seconds with a Z suffix" do
      result = StatusContract.build(base_input(%{now: ~U[2026-05-30 12:00:00.987654Z]}))
      assert result.generated_at == "2026-05-30T12:00:00Z"
    end
  end

  describe "build/1 backups" do
    test "includes a per-job row with last-run status and next fire, consistent with the aggregate" do
      job = job(id: "job-1", name: "Family Photos")
      last_run = %Run{status: "success", started_at: ~U[2026-05-30 06:00:00.000000Z]}

      result =
        StatusContract.build(base_input(%{jobs: [job], last_runs: %{"job-1" => last_run}}))

      assert result.backups.enabled_count == 1
      assert result.backups.failing_count == 0
      assert [row] = result.backups.jobs
      assert row.id == "job-1"
      assert row.name == "Family Photos"
      assert row.enabled == true
      assert row.status == "success"
      assert row.last_run_at == "2026-05-30T06:00:00Z"
      # Per-job next fire is a real ISO timestamp and matches the aggregate soonest.
      assert is_binary(row.next_fire_at)
      assert String.ends_with?(row.next_fire_at, "Z")
      assert result.backups.next_fire_at == row.next_fire_at
    end

    test "reports a nil status and last_run_at for a job that has never run" do
      job = job(id: "job-1")
      result = StatusContract.build(base_input(%{jobs: [job], last_runs: %{"job-1" => nil}}))

      assert [row] = result.backups.jobs
      assert row.status == nil
      assert row.last_run_at == nil
    end

    test "gives a disabled job a nil next fire and excludes it from the enabled count" do
      job = job(id: "job-1", enabled: false)
      result = StatusContract.build(base_input(%{jobs: [job], last_runs: %{"job-1" => nil}}))

      assert result.backups.enabled_count == 0
      assert [row] = result.backups.jobs
      assert row.enabled == false
      assert row.next_fire_at == nil
    end
  end

  describe "build/1 health" do
    test "is degraded with a failing count when an enabled job's last run failed" do
      job = job(id: "job-1")

      result =
        StatusContract.build(
          base_input(%{jobs: [job], last_runs: %{"job-1" => %Run{status: "failed"}}})
        )

      assert result.health == %{level: "degraded", reason: "1 job's last run failed."}
      assert result.backups.failing_count == 1
    end

    test "is down when the self-update failed" do
      result = StatusContract.build(base_input(%{self_update_phase: :failed}))
      assert result.health.level == "down"
      assert result.system.update.state == "failed"
    end
  end

  describe "build/1 self-update" do
    test "surfaces an available update with its version and published_at" do
      release = %{version: "9.9.9", published_at: ~U[2026-06-01 00:00:00Z]}
      result = StatusContract.build(base_input(%{latest_release: release}))

      assert result.system.update == %{
               state: "update_available",
               version: "9.9.9",
               published_at: "2026-06-01T00:00:00Z"
             }
    end

    test "omits the update version when the cached release is not newer" do
      result = StatusContract.build(base_input(%{latest_release: %{version: "0.0.1"}}))
      assert result.system.update == %{state: "idle", version: nil, published_at: nil}
    end
  end

  describe "build/1 activity" do
    test "includes recent runs with duration and a friendly error summary" do
      success = %Run{
        id: "run-1",
        job: %Job{name: "Family Photos"},
        status: "success",
        started_at: ~U[2026-05-30 06:00:00.000000Z],
        finished_at: ~U[2026-05-30 06:05:12.000000Z],
        error_message: nil
      }

      failed = %Run{
        id: "run-2",
        job: %Job{name: "Family Photos"},
        status: "failed",
        started_at: ~U[2026-05-30 05:00:00.000000Z],
        finished_at: ~U[2026-05-30 05:00:03.000000Z],
        error_message: "Upload failed: connection timed out\n\n%RuntimeError{message: \"boom\"}"
      }

      result = StatusContract.build(base_input(%{recent_runs: [success, failed]}))

      assert [first, second] = result.activity

      assert first == %{
               run_id: "run-1",
               job_name: "Family Photos",
               status: "success",
               started_at: "2026-05-30T06:00:00Z",
               finished_at: "2026-05-30T06:05:12Z",
               duration_seconds: 312,
               error: nil
             }

      assert second.status == "failed"
      assert second.duration_seconds == 3
      assert second.error == "Upload failed: connection timed out"
    end

    test "reports nil duration for a still-running run" do
      running = %Run{
        id: "run-3",
        job: %Job{name: "Family Photos"},
        status: "running",
        started_at: ~U[2026-05-30 11:59:00.000000Z],
        finished_at: nil
      }

      result = StatusContract.build(base_input(%{recent_runs: [running]}))
      assert [row] = result.activity
      assert row.duration_seconds == nil
      assert row.finished_at == nil
    end

    test "uses a nil job_name for a run whose job was deleted" do
      orphan = %Run{
        id: "run-4",
        job: nil,
        status: "success",
        started_at: ~U[2026-05-30 06:00:00.000000Z],
        finished_at: ~U[2026-05-30 06:01:00.000000Z]
      }

      result = StatusContract.build(base_input(%{recent_runs: [orphan]}))
      assert [row] = result.activity
      assert row.job_name == nil
    end
  end

  describe "build/1 dotfiles" do
    test "mirrors the dotfiles config and tracked count" do
      config = %Config{
        enabled: true,
        last_push_ok: false,
        last_backup_at: ~U[2026-05-30 09:12:00Z]
      }

      result =
        StatusContract.build(
          base_input(%{dotfiles: %{config: config, tracked_count: 142, last_run: nil}})
        )

      assert result.dotfiles == %{
               enabled: true,
               last_backup_at: "2026-05-30T09:12:00Z",
               last_push_ok: false,
               tracked_count: 142
             }
    end
  end
end
