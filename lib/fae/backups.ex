defmodule Fae.Backups do
  @moduledoc """
  General-purpose backup tool: snapshots a source (file/folder/sqlite),
  optionally packages it (as-is or tar.gz), uploads to a pluggable
  destination (S3-compatible first), and prunes per a per-job retention
  policy.

  State of "is a run in flight?" lives in the supervised
  `Fae.Backups.RunRegistry` and Oban queue. The DB is durable
  persistence for destinations / jobs / run history, not source of
  truth for live state.
  """

  alias Fae.Backups.RunWorker
  alias Fae.Topics

  @doc """
  Subscribes the caller to `backups:runs` — lifecycle messages
  `{:run_started, run_id}` and
  `{:run_finished, run_id, :success | :failed | :skipped, info}`.
  """
  @spec subscribe_runs() :: :ok | {:error, term()}
  def subscribe_runs do
    Phoenix.PubSub.subscribe(Fae.PubSub, Topics.backups_runs())
  end

  @doc """
  Subscribes the caller to `backups:jobs` — `{:job_changed, job_id}`
  fires here when a job is created, updated, enabled, disabled, or
  deleted.
  """
  @spec subscribe_jobs() :: :ok | {:error, term()}
  def subscribe_jobs do
    Phoenix.PubSub.subscribe(Fae.PubSub, Topics.backups_jobs())
  end

  @doc """
  Enqueues an out-of-schedule "Run now" Oban job. Returns the
  inserted job (or an error tuple from `Oban.insert/1`).

  Skip-if-overlapping still applies: if a run is already in flight
  for this job, the worker will record a `"skipped"` run row and
  exit when this job reaches the front of the queue.
  """
  @spec run_now(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def run_now(job_id) when is_binary(job_id) do
    %{"job_id" => job_id, "kind" => "manual"}
    |> RunWorker.new()
    |> Oban.insert()
  end

  @doc """
  App-boot hook. Asks the Scheduler to rehydrate scheduling for
  every enabled job. Called from `Fae.Application` after the
  supervision tree is up.
  """
  @spec boot!() :: :ok
  def boot! do
    if Fae.Backups.Scheduler.enabled?() do
      Fae.Backups.Scheduler.hydrate()
    end

    :ok
  end
end
