defmodule Fae.SelfUpdate.CheckerJob do
  @moduledoc """
  Oban worker that polls the GitHub Releases API for the latest Fae
  tag and persists the result.

  Runs on a 6-hour cron and is also enqueued on app boot. Deduplicated
  within a 1-hour window so rapid restarts and cron firings don't pile
  up duplicate jobs.

  Broadcasts `{:check_started}` and `{:check_complete, outcome}` on
  the `self_update:status` topic so LiveViews can react without
  polling.
  """

  use Oban.Worker,
    queue: :self_update,
    unique: [period: 3600]

  require Logger

  alias Fae.SelfUpdate
  alias Fae.SelfUpdate.{Storage, UpdateChecker}
  alias Fae.Topics

  @impl Oban.Worker
  def perform(_job) do
    if SelfUpdate.enabled?() do
      broadcast({:check_started})
      outcome = run_check()
      broadcast({:check_complete, outcome})
    end

    :ok
  end

  @doc """
  Enqueues an immediate check. Uses `unique: false` to bypass the
  worker-level uniqueness constraint entirely — a manual "Check now"
  is an explicit user action that always runs, even if a prior check
  completed minutes ago and would otherwise hit the dedup window.

  The original implementation used `replace: [scheduled: [...]]`, but
  that only matches conflicts against `:scheduled` jobs. In practice
  the most common conflict is against a `:completed` boot-time check,
  and the replace clause didn't cover that — manual checks silently
  no-op'd (returned the completed job with conflict?: true). The queue
  concurrency is 1, so back-to-back inserts serialize anyway; no need
  for application-level dedup on the manual path.
  """
  @spec enqueue_now() :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_now do
    Oban.insert(new(%{}, unique: false))
  end

  @doc """
  Enqueues a check to run after `delay_seconds`, subject to the
  worker's uniqueness constraint. Used at app boot.
  """
  @spec enqueue_after(pos_integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_after(delay_seconds) when delay_seconds > 0 do
    Oban.insert(new(%{}, schedule_in: delay_seconds))
  end

  defp run_check do
    case Storage.record_check_result(UpdateChecker.latest_release()) do
      {:ok, classification, release} ->
        {classification, release}

      {:error, reason} = error ->
        Logger.warning("update check failed: #{inspect(reason)}")
        error
    end
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Fae.PubSub, Topics.self_update_status(), message)
  end
end
