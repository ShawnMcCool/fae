defmodule Fae.HealthTest do
  use ExUnit.Case, async: true

  alias Fae.Backups.{Job, Run}
  alias Fae.Health

  defp enabled_daily_job(overrides) do
    struct(%Job{enabled: true, recurrence_kind: "daily", time_of_day: "03:00"}, overrides)
  end

  describe "count_failing/2" do
    test "counts enabled jobs whose last run failed" do
      jobs = [enabled_daily_job(id: "a"), enabled_daily_job(id: "b"), enabled_daily_job(id: "c")]

      last_runs = %{
        "a" => %Run{status: "failed"},
        "b" => %Run{status: "success"},
        "c" => %Run{status: "failed"}
      }

      assert Health.count_failing(jobs, last_runs) == 2
    end

    test "treats missing last runs as not-failing" do
      assert Health.count_failing([enabled_daily_job(id: "a")], %{}) == 0
    end
  end

  describe "health/3" do
    test "is :down when the self-update phase is :failed" do
      assert %{level: :down} = Health.health([], %{}, :failed)
    end

    test "is :degraded when any enabled job's last run failed" do
      job = enabled_daily_job(id: "a")

      assert %{level: :degraded, reason: "1 job's last run failed."} =
               Health.health([job], %{"a" => %Run{status: "failed"}}, :idle)
    end

    test "pluralises the reason at 2+" do
      jobs = [enabled_daily_job(id: "a"), enabled_daily_job(id: "b")]
      runs = %{"a" => %Run{status: "failed"}, "b" => %Run{status: "failed"}}
      assert %{reason: "2 jobs' last run failed."} = Health.health(jobs, runs, :idle)
    end

    test "is :healthy with no failing jobs and no failed self-update" do
      job = enabled_daily_job(id: "a")

      assert %{level: :healthy, reason: nil} =
               Health.health([job], %{"a" => %Run{status: "success"}}, :idle)
    end
  end

  describe "soonest_next_fire/2" do
    test "returns nil when no jobs are enabled" do
      assert Health.soonest_next_fire([], ~U[2026-05-17 00:00:00Z]) == nil
    end

    test "picks the earliest next fire time across jobs" do
      now = ~U[2026-05-17 00:00:00Z]
      job_three_am = enabled_daily_job(id: "a", time_of_day: "03:00")
      job_one_am = enabled_daily_job(id: "b", time_of_day: "01:00")

      assert DateTime.compare(
               Health.soonest_next_fire([job_three_am, job_one_am], now),
               ~U[2026-05-17 01:00:00Z]
             ) == :eq
    end
  end

  describe "classify_update/3" do
    test "is :failed when the self-update phase is :failed" do
      assert Health.classify_update(:failed, nil, "1.0.0") == :failed
    end

    test "is :applying while a release is being downloaded or installed" do
      for phase <- [:preparing, :downloading, :extracting, :handing_off] do
        assert Health.classify_update(phase, nil, "1.0.0") == :applying
      end
    end

    test "is :idle when there is no cached release" do
      assert Health.classify_update(:idle, nil, "1.0.0") == :idle
    end

    test "is :update_available when the cached release is newer" do
      assert Health.classify_update(:idle, %{version: "2.0.0"}, "1.0.0") == :update_available
    end

    test "is :idle when the cached release is the same or older" do
      assert Health.classify_update(:idle, %{version: "1.0.0"}, "1.0.0") == :idle
      assert Health.classify_update(:idle, %{version: "0.9.0"}, "1.0.0") == :idle
    end

    test "reads the version from a release tag when there is no version field" do
      assert Health.classify_update(:idle, %{tag: "2.0.0"}, "1.0.0") == :update_available
    end
  end
end
