defmodule Fae.Dotfiles.BackupWorker do
  @moduledoc """
  Oban worker that runs one dotfiles backup cycle. The `:dotfiles`
  queue has concurrency 1, so cycles never overlap.

  On a `"scheduled"` job it first queues the *next* scheduled cycle at
  `now + interval` (self-reschedule, giving interval-since-last
  cadence; a suspend simply makes the queued job overdue and Oban runs
  it once on resume), then runs the pipeline. Manual (`"run now"`) jobs
  skip the reschedule.

  ## Retry policy

  `max_attempts: 5` with a custom backoff (30s, 2m, 10m, 30m).

  Args: `%{"kind" => "scheduled" | "manual"}`.
  """

  use Oban.Worker, queue: :dotfiles, max_attempts: 5

  alias Fae.Dotfiles.{BackupPipeline, Configs, Scheduler}

  @backoff_seconds %{1 => 30, 2 => 120, 3 => 600, 4 => 1800}

  @impl true
  def backoff(%Oban.Job{attempt: attempt}) do
    Map.get(@backoff_seconds, attempt, 1800)
  end

  @impl true
  def perform(%Oban.Job{args: args}) do
    if Map.get(args, "kind") == "scheduled" do
      _ = Scheduler.schedule_next(Configs.get())
    end

    {:ok, _run} = BackupPipeline.run()
    :ok
  end
end
