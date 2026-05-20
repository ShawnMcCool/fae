defmodule Fae.Backups.RunWorker do
  @moduledoc """
  Oban worker that executes one backup run. The `:backups` queue has
  concurrency 1 globally, so different jobs run serially. Per-job
  overlap is additionally enforced by `Fae.Backups.RunRegistry`: a
  second concurrent run of the same job records a `"skipped"` row
  and exits.

  ## Retry policy

  `max_attempts: 5` with a custom backoff (30s, 2m, 10m, 30m). Only
  *transient* errors (DNS, TCP, TLS, timeout, HTTP 5xx, 429 — see
  `Fae.Backups.RunPipeline.classify_error/1`) trigger a retry; the
  worker returns `{:error, _}` and Oban reschedules. Permanent errors
  (auth, missing source, 4xx) return `{:cancel, _}` and never retry.

  During retries the underlying run row is recorded as `"snoozed"`
  rather than `"failed"`, so the dashboard does not flash degraded
  on every transient failure — most commonly the brief
  network-not-ready window after resume from suspend.

  Args: `%{"job_id" => uuid, "kind" => "scheduled" | "manual"}`.
  """
  use Oban.Worker, queue: :backups, max_attempts: 5

  require Logger

  alias Fae.Backups.{Jobs, RunPipeline, RunRegistry, Runs}
  alias Fae.Topics

  @backoff_seconds %{1 => 30, 2 => 120, 3 => 600, 4 => 1800}

  @impl true
  def backoff(%Oban.Job{attempt: attempt}) do
    Map.get(@backoff_seconds, attempt, 1800)
  end

  @impl true
  def perform(%Oban.Job{args: %{"job_id" => job_id, "kind" => kind}} = oban_job) do
    case RunRegistry.register(job_id) do
      :ok ->
        try do
          do_perform(job_id, kind, oban_job)
        after
          RunRegistry.unregister(job_id)
        end

      {:error, :overlap} ->
        record_skipped(job_id)
        {:cancel, :overlap}
    end
  end

  defp do_perform(job_id, kind, oban_job) do
    case Jobs.get(job_id) do
      nil ->
        Logger.warning("Backup job #{job_id} no longer exists; cancelling")
        {:cancel, :job_deleted}

      %{enabled: false} ->
        Logger.info("Backup job #{job_id} is disabled; cancelling")
        {:cancel, :disabled}

      job ->
        if kind == "scheduled" do
          _ = schedule_next(job)
        end

        last_attempt? = oban_job.attempt >= oban_job.max_attempts

        case RunPipeline.run(job, last_attempt?: last_attempt?) do
          {:ok, _} -> :ok
          {:snoozed, reason} -> {:error, {:transient, reason}}
          {:failed, reason} -> {:cancel, reason}
        end
    end
  end

  defp schedule_next(job) do
    next = Fae.Backups.Recurrence.next_fire(job, Fae.Clock.now())

    %{"job_id" => job.id, "kind" => "scheduled"}
    |> __MODULE__.new(scheduled_at: next)
    |> Oban.insert()
  end

  defp record_skipped(job_id) do
    case Runs.record_skipped(job_id, :overlap, Fae.Clock.now()) do
      {:ok, run} ->
        Phoenix.PubSub.broadcast(
          Fae.PubSub,
          Topics.backups_runs(),
          {:run_finished, run.id, :skipped, :overlap}
        )

      {:error, reason} ->
        Logger.warning("Failed to record skipped run for #{job_id}: #{inspect(reason)}")
    end

    :ok
  end
end
