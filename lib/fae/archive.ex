defmodule Fae.Archive do
  @moduledoc """
  Bulk archival tool: streams a local directory tree up to a storage
  destination, verifying each file (transit `Content-MD5` + recorded
  SHA256) so the user can later reclaim local space. Distinct from
  `Fae.Backups` — this is a one-shot *move*, not a scheduled, rotating
  *copy*.

  Live "is a run in flight / how far along" state lives in the supervised
  `Fae.Archive.ProgressServer`; the DB holds durable run/item records and
  the final tally, not live state.
  """
  alias Fae.Archive.ArchiveWorker
  alias Fae.Archive.Items
  alias Fae.Archive.Run
  alias Fae.Archive.Runs
  alias Fae.Topics

  @doc """
  Subscribes the caller to `archive:runs` — `{:run_changed, run_id}` on
  any run mutation and `{:run_finished, run_id, status}` on completion.
  """
  @spec subscribe_runs() :: :ok | {:error, term()}
  def subscribe_runs, do: Phoenix.PubSub.subscribe(Fae.PubSub, Topics.archive_runs())

  @doc """
  Subscribes the caller to `archive:progress` —
  `{:archive_progress, run_id, snapshot}` throttled updates while a run
  is uploading.
  """
  @spec subscribe_progress() :: :ok | {:error, term()}
  def subscribe_progress, do: Phoenix.PubSub.subscribe(Fae.PubSub, Topics.archive_progress())

  @doc "Creates a run from user input and enqueues it for execution."
  @spec start_archive(map()) :: {:ok, Run.t()} | {:error, term()}
  def start_archive(attrs) do
    with {:ok, run} <- Runs.create(attrs),
         {:ok, _job} <- enqueue(run.id) do
      {:ok, run}
    end
  end

  @doc """
  Reconfigures an archive by replacing it: creates a new archive from
  `attrs` and retires the old one (clone-and-replace). Refuses while a
  sync is in flight. Bucket objects are not deleted; if the source,
  remote folder, or destination changed, the next sync uploads into the
  new location and the old objects remain where they are.
  """
  @spec replace(Ecto.UUID.t(), map()) :: {:ok, Run.t()} | {:error, term()}
  def replace(old_run_id, attrs) do
    case Runs.get(old_run_id) do
      nil -> {:error, :not_found}
      %Run{status: status} when status in ["scanning", "uploading"] -> {:error, :busy}
      %Run{} = old -> Runs.replace(old, attrs)
    end
  end

  @doc "In-place rename of an archive (the friendly name only)."
  @spec rename(Ecto.UUID.t(), map()) :: {:ok, Run.t()} | {:error, term()}
  def rename(run_id, attrs) do
    case Runs.get(run_id) do
      nil -> {:error, :not_found}
      %Run{} = run -> Runs.rename(run, attrs)
    end
  end

  @doc """
  Re-runs an archive: the worker re-scans the source (picking up files
  added since the last run) and uploads everything still pending,
  skipping files already uploaded. Failed items are reset to pending
  first so transient failures are retried too. This is the "Sync now"
  action behind a manual drop-folder mirror.
  """
  @spec sync(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def sync(run_id) do
    case Runs.get(run_id) do
      nil ->
        {:error, :not_found}

      run ->
        _ = Items.reset_failed(run.id)
        enqueue(run.id)
    end
  end

  @doc """
  App-boot hook: re-enqueues runs left mid-flight by a restart. The
  worker resumes idempotently, skipping already-uploaded files.
  """
  @spec boot!() :: :ok
  def boot! do
    if resume_on_boot?() do
      for run <- Runs.resumable(), do: enqueue(run.id)
    end

    :ok
  end

  defp enqueue(run_id) do
    %{"run_id" => run_id} |> ArchiveWorker.new() |> Oban.insert()
  end

  defp resume_on_boot? do
    Application.get_env(:fae, __MODULE__, []) |> Keyword.get(:resume_on_boot, true)
  end
end
