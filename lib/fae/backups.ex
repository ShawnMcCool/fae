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
end
