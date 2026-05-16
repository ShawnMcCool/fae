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
  Enqueues an immediate check, bypassing the 1-hour unique window so a
  manual "Check now" always wins.
  """
  @spec enqueue_now() :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_now do
    Oban.insert(new(%{}, replace: [scheduled: [:scheduled_at, :args]]))
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
