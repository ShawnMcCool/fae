defmodule Fae.Backups.RunWorker do
  @moduledoc """
  Oban worker that executes one backup run. The `:backups` queue has
  concurrency 1 globally, so different jobs run serially. Per-job
  overlap is additionally enforced by `Fae.Backups.RunRegistry`: a
  second concurrent run of the same job records a `"skipped"` row
  and exits.

  `max_attempts: 1` — a failed backup isn't auto-retried; the user
  sees the failure in the LiveView and either fixes the destination
  or waits for the next scheduled tick. Retries with backoff against
  e.g. a misconfigured bucket are just noise.

  Args: `%{"job_id" => uuid, "kind" => "scheduled" | "manual"}`.
  """
  use Oban.Worker, queue: :backups, max_attempts: 1

  require Logger

  alias Fae.Backups.{Jobs, RunPipeline, RunRegistry, Runs}
  alias Fae.Topics

  @impl true
  def perform(%Oban.Job{args: %{"job_id" => job_id, "kind" => kind}}) do
    case RunRegistry.register(job_id) do
      :ok ->
        try do
          do_perform(job_id, kind)
        after
          RunRegistry.unregister(job_id)
        end

      {:error, :overlap} ->
        record_skipped(job_id)
        {:cancel, :overlap}
    end
  end

  defp do_perform(job_id, kind) do
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

        case RunPipeline.run(job) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
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
