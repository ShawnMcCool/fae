defmodule FaeWeb.StatusContract do
  @moduledoc """
  Pure presenter that shapes a `Fae.Status` snapshot into the machine-facing
  JSON contract served at `GET /api/status` (see `docs/api/status.md`).

  The map this returns is JSON-ready: every timestamp is already an ISO-8601
  UTC string (or `nil`), and every value is a plain string/number/boolean/map,
  so the controller can hand it straight to `json/2`. Health derivations go
  through `Fae.Health`, so the contract can never disagree with the dashboard.

  Side-effect-free; exercised by async unit tests.
  """

  alias Fae.Backups.{Recurrence, Run}
  alias Fae.Health

  # Bump only on a breaking change to the payload shape; additive fields keep
  # this constant (see the versioning policy in docs/api/status.md).
  @schema_version 1

  @spec build(Fae.Status.t()) :: map()
  def build(input) do
    enabled_jobs = Enum.filter(input.jobs, & &1.enabled)

    update_state =
      Health.classify_update(input.self_update_phase, input.latest_release, input.version)

    health = Health.health(enabled_jobs, input.last_runs, input.self_update_phase)

    %{
      schema: @schema_version,
      generated_at: iso8601(input.now),
      health: %{level: Atom.to_string(health.level), reason: health.reason},
      system: %{
        version: input.version,
        booted_at: iso8601(input.system.boot_at),
        uptime_seconds: input.system.uptime_seconds,
        update: update(update_state, input.latest_release)
      },
      backups: %{
        enabled_count: length(enabled_jobs),
        failing_count: Health.count_failing(enabled_jobs, input.last_runs),
        next_fire_at: iso8601(Health.soonest_next_fire(enabled_jobs, input.now)),
        jobs: Enum.map(input.jobs, &job_row(&1, input.last_runs, input.now))
      },
      activity: Enum.map(input.recent_runs, &activity_row/1),
      dotfiles: dotfiles(input.dotfiles)
    }
  end

  defp update(:update_available, release) do
    %{
      state: "update_available",
      version: release_version(release),
      published_at: iso8601(Map.get(release, :published_at))
    }
  end

  defp update(state, _release) do
    %{state: Atom.to_string(state), version: nil, published_at: nil}
  end

  defp release_version(release) do
    Map.get(release, :version) || Map.get(release, :tag)
  end

  defp job_row(job, last_runs, now) do
    run = Map.get(last_runs, job.id)

    %{
      id: job.id,
      name: job.name,
      enabled: job.enabled,
      status: run && run.status,
      last_run_at: iso8601(run && run.started_at),
      next_fire_at: if(job.enabled, do: iso8601(Recurrence.next_fire(job, now)), else: nil)
    }
  end

  defp activity_row(%Run{} = run) do
    %{
      run_id: run.id,
      job_name: job_name(run),
      status: run.status,
      started_at: iso8601(run.started_at),
      finished_at: iso8601(run.finished_at),
      duration_seconds: duration_seconds(run),
      error: friendly_error(run.error_message)
    }
  end

  defp job_name(%Run{job: %{name: name}}) when is_binary(name), do: name
  defp job_name(_run), do: nil

  defp duration_seconds(%Run{
         started_at: %DateTime{} = started,
         finished_at: %DateTime{} = finished
       }) do
    max(DateTime.diff(finished, started, :second), 0)
  end

  defp duration_seconds(_run), do: nil

  defp dotfiles(%{config: config, tracked_count: tracked_count}) do
    %{
      enabled: config.enabled,
      last_backup_at: iso8601(config.last_backup_at),
      last_push_ok: config.last_push_ok,
      tracked_count: tracked_count
    }
  end

  # The stored error_message is "<friendly summary>\n\n<inspect>"; the contract
  # exposes only the friendly summary, untruncated.
  defp friendly_error(nil), do: nil
  defp friendly_error(""), do: nil

  defp friendly_error(message) when is_binary(message) do
    case message |> String.split("\n\n", parts: 2) |> List.first() |> String.trim() do
      "" -> nil
      summary -> summary
    end
  end

  defp iso8601(nil), do: nil

  # Machine-facing contract, not user-facing display: the JSON timestamps MUST
  # be raw ISO-8601 UTC for consumers to parse, so TimeDisplay (which localizes
  # for the UI) is deliberately not used here.
  defp iso8601(%DateTime{} = datetime) do
    # credo:disable-for-next-line Fae.Credo.Check.UnlocalizedDateTime
    datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
