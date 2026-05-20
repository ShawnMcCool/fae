defmodule FaeWeb.DashboardView do
  @moduledoc """
  Pure presenter for `FaeWeb.DashboardLive`. Takes the raw operational
  state read by the LiveView and returns a fully-shaped view map for
  rendering. All functions are side-effect-free so they can be
  exercised by async unit tests.

  Per decision-019 (LiveView logic extraction): the LiveView is only
  responsible for subscribing, refetching, and rendering — every
  branch, derivation, and label lives here.
  """

  alias Fae.Backups.{Job, Recurrence, Run}

  @recent_activity_error_preview_chars 120

  @type health_level :: :healthy | :degraded | :down
  @type health :: %{level: health_level(), reason: String.t() | nil}

  @type job_row :: %{
          job: Job.t(),
          last_run: Run.t() | nil,
          next_fire: DateTime.t() | nil,
          schedule_summary: String.t(),
          status_label: String.t(),
          status_class: String.t()
        }

  @type activity_row :: %{
          run: Run.t(),
          job_name: String.t(),
          started_at: DateTime.t() | nil,
          duration_label: String.t(),
          status_class: String.t(),
          error_preview: String.t() | nil
        }

  @type self_update_state ::
          :idle
          | :checking
          | :update_available
          | :applying
          | :failed

  @type input :: %{
          jobs: [Job.t()],
          last_runs: %{optional(Ecto.UUID.t()) => Run.t() | nil},
          recent_runs: [Run.t()],
          destinations: [Fae.Backups.Destination.t()],
          version: String.t(),
          latest_release: map() | nil,
          self_update_phase: atom(),
          self_update_error: term() | nil,
          system: %{boot_at: DateTime.t(), uptime_seconds: non_neg_integer()},
          now: DateTime.t()
        }

  @type output :: %{
          health: health(),
          system: %{
            version: String.t(),
            boot_at: DateTime.t(),
            uptime_label: String.t(),
            update_state: self_update_state(),
            update_version: String.t() | nil,
            update_published_at: DateTime.t() | nil,
            self_update_phase: atom(),
            self_update_error: term() | nil
          },
          jobs: %{
            enabled_count: non_neg_integer(),
            failing_count: non_neg_integer(),
            soonest_next_fire: DateTime.t() | nil,
            rows: [job_row()]
          },
          activity: [activity_row()],
          destinations: [Fae.Backups.Destination.t()]
        }

  @spec build(input()) :: output()
  def build(input) do
    enabled_jobs = Enum.filter(input.jobs, & &1.enabled)
    job_rows = build_job_rows(input.jobs, input.last_runs, input.now)
    activity = build_activity(input.recent_runs)

    update_state =
      classify_self_update(input.self_update_phase, input.latest_release, input.version)

    %{
      health: health(enabled_jobs, input.last_runs, input.self_update_phase),
      system: %{
        version: input.version,
        boot_at: input.system.boot_at,
        uptime_label: uptime_label(input.system.uptime_seconds),
        update_state: update_state,
        update_version: get_release_field(input.latest_release, :version),
        update_published_at: get_release_field(input.latest_release, :published_at),
        self_update_phase: input.self_update_phase,
        self_update_error: input.self_update_error
      },
      jobs: %{
        enabled_count: length(enabled_jobs),
        failing_count: count_failing(enabled_jobs, input.last_runs),
        soonest_next_fire: soonest_next_fire(enabled_jobs, input.now),
        rows: job_rows
      },
      activity: activity,
      destinations: input.destinations
    }
  end

  @spec health([Job.t()], %{optional(Ecto.UUID.t()) => Run.t() | nil}, atom()) :: health()
  def health(enabled_jobs, last_runs, self_update_phase) do
    cond do
      self_update_phase == :failed ->
        %{level: :down, reason: "Self-update failed — see Updates page."}

      (failing = count_failing(enabled_jobs, last_runs)) > 0 ->
        %{level: :degraded, reason: failing_reason(failing)}

      true ->
        %{level: :healthy, reason: nil}
    end
  end

  defp failing_reason(1), do: "1 job's last run failed."
  defp failing_reason(n) when n > 1, do: "#{n} jobs' last run failed."

  @spec count_failing([Job.t()], %{optional(Ecto.UUID.t()) => Run.t() | nil}) :: non_neg_integer()
  def count_failing(enabled_jobs, last_runs) do
    Enum.count(enabled_jobs, fn job ->
      case Map.get(last_runs, job.id) do
        %Run{status: "failed"} -> true
        _ -> false
      end
    end)
  end

  @spec soonest_next_fire([Job.t()], DateTime.t()) :: DateTime.t() | nil
  def soonest_next_fire([], _now), do: nil

  def soonest_next_fire(enabled_jobs, now) do
    enabled_jobs
    |> Enum.map(&Recurrence.next_fire(&1, now))
    |> Enum.min(DateTime, fn -> nil end)
  end

  @doc """
  Renders a duration in seconds as a compact human label. Tiers:

      0..59       -> "23s"
      60..3599    -> "4m 12s"
      3600..86399 -> "1h 03m"
      >= 86400    -> "2d 04h 17m"
  """
  @spec uptime_label(non_neg_integer()) :: String.t()
  def uptime_label(seconds) when is_integer(seconds) and seconds >= 0 do
    seconds_per_minute = 60
    seconds_per_hour = 3600
    seconds_per_day = 86_400

    cond do
      seconds < seconds_per_minute ->
        "#{seconds}s"

      seconds < seconds_per_hour ->
        minutes = div(seconds, seconds_per_minute)
        rest = rem(seconds, seconds_per_minute)
        "#{minutes}m #{pad2(rest)}s"

      seconds < seconds_per_day ->
        hours = div(seconds, seconds_per_hour)
        minutes = div(rem(seconds, seconds_per_hour), seconds_per_minute)
        "#{hours}h #{pad2(minutes)}m"

      true ->
        days = div(seconds, seconds_per_day)
        hours = div(rem(seconds, seconds_per_day), seconds_per_hour)
        minutes = div(rem(seconds, seconds_per_hour), seconds_per_minute)
        "#{days}d #{pad2(hours)}h #{pad2(minutes)}m"
    end
  end

  @spec duration_label(Run.t(), DateTime.t()) :: String.t()
  def duration_label(%Run{started_at: nil}, _now), do: "—"

  def duration_label(%Run{started_at: started, finished_at: nil}, %DateTime{} = now) do
    seconds = max(DateTime.diff(now, started, :second), 0)
    "running · #{uptime_label(seconds)}"
  end

  def duration_label(%Run{started_at: started, finished_at: finished}, _now) do
    seconds = max(DateTime.diff(finished, started, :second), 0)
    uptime_label(seconds)
  end

  @spec status_class(String.t() | nil) :: String.t()
  def status_class("success"), do: "badge-success"
  def status_class("running"), do: "badge-info"
  def status_class("failed"), do: "badge-error"
  def status_class("skipped"), do: "badge-warning"
  def status_class("snoozed"), do: "badge-warning"
  def status_class(_), do: "badge-ghost"

  @spec schedule_summary(Job.t()) :: String.t()
  def schedule_summary(%Job{enabled: false}), do: "(disabled)"
  def schedule_summary(%Job{recurrence_kind: "hourly"}), do: "Hourly"
  def schedule_summary(%Job{recurrence_kind: "daily", time_of_day: t}), do: "Daily at #{t}"

  def schedule_summary(%Job{recurrence_kind: "weekly", time_of_day: t, day_of_week: dow}),
    do: "Weekly #{day_name(dow)} at #{t}"

  def schedule_summary(%Job{recurrence_kind: "monthly", time_of_day: t, day_of_month: dom}),
    do: "Monthly day #{dom} at #{t}"

  def schedule_summary(_), do: "—"

  @spec health_class(health_level()) :: String.t()
  def health_class(:healthy), do: "badge-success"
  def health_class(:degraded), do: "badge-warning"
  def health_class(:down), do: "badge-error"

  @spec health_label(health_level()) :: String.t()
  def health_label(:healthy), do: "Healthy"
  def health_label(:degraded), do: "Degraded"
  def health_label(:down), do: "Down"

  defp build_job_rows(jobs, last_runs, now) do
    Enum.map(jobs, fn job ->
      run = Map.get(last_runs, job.id)

      %{
        job: job,
        last_run: run,
        next_fire: if(job.enabled, do: Recurrence.next_fire(job, now), else: nil),
        schedule_summary: schedule_summary(job),
        status_label: status_label(run),
        status_class: status_class(run && run.status)
      }
    end)
  end

  defp build_activity(recent_runs) do
    Enum.map(recent_runs, fn run ->
      %{
        run: run,
        job_name: job_name_for(run),
        started_at: run.started_at,
        duration_label: duration_label_for_listing(run),
        status_class: status_class(run.status),
        error_preview: error_preview(run.error_message)
      }
    end)
  end

  defp duration_label_for_listing(%Run{started_at: nil}), do: "—"

  defp duration_label_for_listing(%Run{finished_at: nil}), do: "running"

  defp duration_label_for_listing(%Run{started_at: started, finished_at: finished}) do
    seconds = max(DateTime.diff(finished, started, :second), 0)
    uptime_label(seconds)
  end

  defp job_name_for(%Run{job: %Job{name: name}}) when is_binary(name), do: name
  defp job_name_for(_), do: "(deleted job)"

  defp status_label(nil), do: "no runs yet"
  defp status_label(%Run{status: status}) when is_binary(status), do: status
  defp status_label(_), do: "—"

  defp error_preview(nil), do: nil
  defp error_preview(""), do: nil

  defp error_preview(message) when is_binary(message) do
    trimmed = String.trim(message)

    if String.length(trimmed) > @recent_activity_error_preview_chars do
      String.slice(trimmed, 0, @recent_activity_error_preview_chars) <> "…"
    else
      trimmed
    end
  end

  defp classify_self_update(:failed, _release, _local), do: :failed

  defp classify_self_update(phase, _release, _local)
       when phase in [:preparing, :downloading, :extracting, :handing_off], do: :applying

  defp classify_self_update(_phase, nil, _local), do: :idle

  defp classify_self_update(_phase, release, local) do
    case Fae.Version.compare_versions(release_version(release), local) do
      :gt -> :update_available
      _ -> :idle
    end
  end

  defp release_version(%{version: v}) when is_binary(v), do: v
  defp release_version(%{tag: tag}) when is_binary(tag), do: tag
  defp release_version(_), do: ""

  defp get_release_field(nil, _key), do: nil
  defp get_release_field(release, key), do: Map.get(release, key)

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: Integer.to_string(n)

  defp day_name(0), do: "Sun"
  defp day_name(1), do: "Mon"
  defp day_name(2), do: "Tue"
  defp day_name(3), do: "Wed"
  defp day_name(4), do: "Thu"
  defp day_name(5), do: "Fri"
  defp day_name(6), do: "Sat"
  defp day_name(_), do: "?"
end
