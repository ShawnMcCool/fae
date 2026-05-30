defmodule FaeWeb.DashboardViewTest do
  use ExUnit.Case, async: true

  alias Fae.Backups.{Job, Run}
  alias FaeWeb.DashboardView

  describe "uptime_label/1" do
    test "renders seconds under a minute" do
      assert DashboardView.uptime_label(0) == "0s"
      assert DashboardView.uptime_label(23) == "23s"
      assert DashboardView.uptime_label(59) == "59s"
    end

    test "renders minutes-and-seconds under an hour" do
      assert DashboardView.uptime_label(60) == "1m 00s"
      assert DashboardView.uptime_label(252) == "4m 12s"
      assert DashboardView.uptime_label(3599) == "59m 59s"
    end

    test "renders hours-and-minutes under a day" do
      assert DashboardView.uptime_label(3600) == "1h 00m"
      assert DashboardView.uptime_label(3780) == "1h 03m"
      assert DashboardView.uptime_label(86_399) == "23h 59m"
    end

    test "renders days-hours-minutes for >= a day" do
      assert DashboardView.uptime_label(86_400) == "1d 00h 00m"
      assert DashboardView.uptime_label(2 * 86_400 + 4 * 3600 + 17 * 60) == "2d 04h 17m"
    end
  end

  describe "status_class/1" do
    test "maps known statuses to daisyUI badge variants" do
      assert DashboardView.status_class("success") == "badge-success"
      assert DashboardView.status_class("running") == "badge-info"
      assert DashboardView.status_class("failed") == "badge-error"
      assert DashboardView.status_class("skipped") == "badge-warning"
    end

    test "falls back to badge-ghost for nil or unknown" do
      assert DashboardView.status_class(nil) == "badge-ghost"
      assert DashboardView.status_class("queued") == "badge-ghost"
    end
  end

  describe "schedule_summary/1" do
    test "hides disabled jobs behind a single label" do
      job = %Job{enabled: false, recurrence_kind: "daily", time_of_day: "03:00"}
      assert DashboardView.schedule_summary(job) == "(disabled)"
    end

    test "describes each recurrence kind" do
      assert DashboardView.schedule_summary(%Job{enabled: true, recurrence_kind: "hourly"}) ==
               "Hourly"

      assert DashboardView.schedule_summary(%Job{
               enabled: true,
               recurrence_kind: "daily",
               time_of_day: "03:00"
             }) == "Daily at 03:00"

      assert DashboardView.schedule_summary(%Job{
               enabled: true,
               recurrence_kind: "weekly",
               time_of_day: "04:30",
               day_of_week: 1
             }) == "Weekly Mon at 04:30"

      assert DashboardView.schedule_summary(%Job{
               enabled: true,
               recurrence_kind: "monthly",
               time_of_day: "01:00",
               day_of_month: 15
             }) == "Monthly day 15 at 01:00"
    end
  end

  describe "duration_label/2" do
    test "returns em-dash for runs with no started_at" do
      run = %Run{started_at: nil, finished_at: nil}
      assert DashboardView.duration_label(run, ~U[2026-05-17 00:00:00Z]) == "—"
    end

    test "labels in-flight runs with elapsed time" do
      run = %Run{started_at: ~U[2026-05-17 00:00:00Z], finished_at: nil}
      now = ~U[2026-05-17 00:00:42Z]
      assert DashboardView.duration_label(run, now) == "running · 42s"
    end

    test "labels completed runs with their duration" do
      run = %Run{
        started_at: ~U[2026-05-17 00:00:00Z],
        finished_at: ~U[2026-05-17 00:01:15Z]
      }

      assert DashboardView.duration_label(run, ~U[2026-05-17 00:02:00Z]) == "1m 15s"
    end
  end

  describe "count_failing/2" do
    test "counts enabled jobs whose last run failed" do
      job_a = enabled_daily_job(id: "a")
      job_b = enabled_daily_job(id: "b")
      job_c = enabled_daily_job(id: "c")

      last_runs = %{
        "a" => %Run{status: "failed"},
        "b" => %Run{status: "success"},
        "c" => %Run{status: "failed"}
      }

      assert DashboardView.count_failing([job_a, job_b, job_c], last_runs) == 2
    end

    test "treats missing last runs as not-failing" do
      job = enabled_daily_job(id: "a")
      assert DashboardView.count_failing([job], %{}) == 0
    end
  end

  describe "health/3" do
    test "is :down when the self-update GenServer is in :failed" do
      assert %{level: :down} = DashboardView.health([], %{}, :failed)
    end

    test "is :degraded when any enabled job's last run failed" do
      job = enabled_daily_job(id: "a")

      assert %{level: :degraded, reason: "1 job's last run failed."} =
               DashboardView.health([job], %{"a" => %Run{status: "failed"}}, :idle)
    end

    test "pluralises the reason at 2+" do
      jobs = [enabled_daily_job(id: "a"), enabled_daily_job(id: "b")]

      runs = %{
        "a" => %Run{status: "failed"},
        "b" => %Run{status: "failed"}
      }

      assert %{reason: "2 jobs' last run failed."} = DashboardView.health(jobs, runs, :idle)
    end

    test "is :healthy when there are no failing jobs and no failed self-update" do
      job = enabled_daily_job(id: "a")

      assert %{level: :healthy, reason: nil} =
               DashboardView.health([job], %{"a" => %Run{status: "success"}}, :idle)
    end
  end

  describe "soonest_next_fire/2" do
    test "returns nil when no jobs are enabled" do
      assert DashboardView.soonest_next_fire([], ~U[2026-05-17 00:00:00Z]) == nil
    end

    test "picks the earliest next fire time across jobs" do
      now = ~U[2026-05-17 00:00:00Z]

      job_three_am = enabled_daily_job(id: "a", time_of_day: "03:00")
      job_one_am = enabled_daily_job(id: "b", time_of_day: "01:00")

      assert DateTime.compare(
               DashboardView.soonest_next_fire([job_three_am, job_one_am], now),
               ~U[2026-05-17 01:00:00Z]
             ) == :eq
    end
  end

  describe "build/1" do
    test "shapes the full view map for the LiveView" do
      now = ~U[2026-05-17 09:00:00Z]
      job = enabled_daily_job(id: "a", name: "Daily Fae DB", time_of_day: "03:00")
      last_run = %Run{status: "success", started_at: ~U[2026-05-17 03:00:00Z]}

      run_one = %Run{
        id: "r1",
        job: job,
        status: "success",
        started_at: ~U[2026-05-17 03:00:00Z],
        finished_at: ~U[2026-05-17 03:00:10Z]
      }

      run_two = %Run{
        id: "r2",
        job: job,
        status: "failed",
        started_at: ~U[2026-05-16 03:00:00Z],
        finished_at: ~U[2026-05-16 03:00:05Z],
        error_message: "boom"
      }

      view =
        DashboardView.build(%{
          jobs: [job],
          last_runs: %{"a" => last_run},
          recent_runs: [run_one, run_two],
          destinations: [],
          version: "0.2.0",
          latest_release: nil,
          self_update_phase: :idle,
          self_update_error: nil,
          system: %{boot_at: ~U[2026-05-17 08:00:00Z], uptime_seconds: 3600},
          now: now
        })

      assert view.health.level == :healthy
      assert view.system.version == "0.2.0"
      assert view.system.uptime_label == "1h 00m"
      assert view.system.update_state == :idle
      assert view.jobs.enabled_count == 1
      assert view.jobs.failing_count == 0
      assert view.jobs.soonest_next_fire == ~U[2026-05-18 03:00:00Z]
      assert [job_row] = view.jobs.rows
      assert job_row.job.id == "a"
      assert job_row.schedule_summary == "Daily at 03:00"
      assert job_row.status_class == "badge-success"
      assert [activity_one, activity_two] = view.activity
      assert activity_one.run.id == "r1"
      assert activity_one.duration_label == "10s"
      assert activity_one.status_class == "badge-success"
      assert activity_two.run.id == "r2"
      assert activity_two.error_preview == "boom"
    end

    test "classifies an update as :update_available when latest_release > running" do
      view =
        DashboardView.build(%{
          jobs: [],
          last_runs: %{},
          recent_runs: [],
          destinations: [],
          version: "0.2.0",
          latest_release: %{version: "0.3.0", published_at: ~U[2026-05-17 00:00:00Z]},
          self_update_phase: :idle,
          self_update_error: nil,
          system: %{boot_at: ~U[2026-05-17 00:00:00Z], uptime_seconds: 0},
          now: ~U[2026-05-17 00:00:01Z]
        })

      assert view.system.update_state == :update_available
      assert view.system.update_version == "0.3.0"
    end

    test "classifies as :applying while the updater is mid-cycle" do
      view =
        DashboardView.build(%{
          jobs: [],
          last_runs: %{},
          recent_runs: [],
          destinations: [],
          version: "0.2.0",
          latest_release: %{version: "0.3.0", published_at: ~U[2026-05-17 00:00:00Z]},
          self_update_phase: :downloading,
          self_update_error: nil,
          system: %{boot_at: ~U[2026-05-17 00:00:00Z], uptime_seconds: 0},
          now: ~U[2026-05-17 00:00:01Z]
        })

      assert view.system.update_state == :applying
    end

    test "trims long error messages in the activity feed" do
      message = String.duplicate("x", 500)

      run = %Run{
        id: "r1",
        job: enabled_daily_job(id: "a", name: "Daily Fae DB"),
        status: "failed",
        started_at: ~U[2026-05-17 03:00:00Z],
        finished_at: ~U[2026-05-17 03:00:05Z],
        error_message: message
      }

      view =
        DashboardView.build(%{
          jobs: [],
          last_runs: %{},
          recent_runs: [run],
          destinations: [],
          version: "0.2.0",
          latest_release: nil,
          self_update_phase: :idle,
          self_update_error: nil,
          system: %{boot_at: ~U[2026-05-17 00:00:00Z], uptime_seconds: 0},
          now: ~U[2026-05-17 03:00:10Z]
        })

      assert [%{error_preview: preview}] = view.activity
      assert String.ends_with?(preview, "…")
      assert String.length(preview) < String.length(message)
    end

    test "labels an unknown / deleted job in the activity feed" do
      run = %Run{
        id: "r1",
        job: nil,
        status: "success",
        started_at: ~U[2026-05-17 03:00:00Z],
        finished_at: ~U[2026-05-17 03:00:10Z]
      }

      view =
        DashboardView.build(%{
          jobs: [],
          last_runs: %{},
          recent_runs: [run],
          destinations: [],
          version: "0.2.0",
          latest_release: nil,
          self_update_phase: :idle,
          self_update_error: nil,
          system: %{boot_at: ~U[2026-05-17 00:00:00Z], uptime_seconds: 0},
          now: ~U[2026-05-17 03:00:10Z]
        })

      assert [%{job_name: "(deleted job)"}] = view.activity
    end
  end

  describe "build/1 dotfiles shaping" do
    test "shapes the dotfiles section from config, tracked count, and last run" do
      view = build_with_dotfiles()
      assert view.dotfiles.enabled == true
      assert view.dotfiles.tracked_count == 3
      assert view.dotfiles.last_backup_at == ~U[2026-05-17 02:00:00Z]
      assert view.dotfiles.last_push_ok == true
      assert view.dotfiles.repo_remote == "git@example.com:dotfiles.git"
    end

    test "reflects a failed push and a disabled config" do
      view =
        build_with_dotfiles(
          config: %Fae.Dotfiles.Config{
            enabled: false,
            last_backup_at: nil,
            last_push_ok: false,
            remote_url: nil
          },
          tracked_count: 0
        )

      assert view.dotfiles.enabled == false
      assert view.dotfiles.last_push_ok == false
      assert view.dotfiles.tracked_count == 0
      assert view.dotfiles.last_backup_at == nil
      assert view.dotfiles.repo_remote == nil
    end
  end

  defp build_with_dotfiles(opts \\ []) do
    config =
      Keyword.get(opts, :config, %Fae.Dotfiles.Config{
        enabled: true,
        last_backup_at: ~U[2026-05-17 02:00:00Z],
        last_push_ok: true,
        remote_url: "git@example.com:dotfiles.git"
      })

    DashboardView.build(%{
      jobs: [],
      last_runs: %{},
      recent_runs: [],
      destinations: [],
      version: "0.2.0",
      latest_release: nil,
      self_update_phase: :idle,
      self_update_error: nil,
      system: %{boot_at: ~U[2026-05-17 00:00:00Z], uptime_seconds: 0},
      now: ~U[2026-05-17 09:00:00Z],
      dotfiles: %{
        config: config,
        tracked_count: Keyword.get(opts, :tracked_count, 3),
        last_run: Keyword.get(opts, :last_run)
      }
    })
  end

  defp enabled_daily_job(opts) do
    %Job{
      id: Keyword.fetch!(opts, :id),
      name: Keyword.get(opts, :name, "Job #{Keyword.fetch!(opts, :id)}"),
      enabled: true,
      recurrence_kind: "daily",
      time_of_day: Keyword.get(opts, :time_of_day, "03:00")
    }
  end
end
