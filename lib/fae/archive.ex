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
  alias Fae.Archive.KeyBuilder
  alias Fae.Archive.Run
  alias Fae.Archive.Runs
  alias Fae.Storage.Destinations
  alias Fae.Topics

  @empty_slug_message "must contain at least one letter or number"

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
  Starts a quick archive: one-shot, upload-dated. `attrs` are the form
  params (`name` = the label text, `source_path`, `destination_id`). The
  dated folder path is composed from the destination's `quick_archive_prefix`,
  `today`, and a slug of the name, then stored as the run's `label` so the
  worker's normal key path applies unchanged. `today` is injected (defaults
  to `Date.utc_today/0`) so the path reflects when the operator clicked.

  Returns `{:error, %Ecto.Changeset{}}` for form errors (missing destination,
  a name with nothing slug-worthy) and `{:error, :collision, existing_run}`
  when the same label was already archived to the same destination today.
  """
  @spec start_quick_archive(map(), Date.t()) ::
          {:ok, Run.t()} | {:error, Ecto.Changeset.t()} | {:error, :collision, Run.t()}
  def start_quick_archive(attrs, today \\ Date.utc_today()) do
    with {:ok, destination} <- fetch_destination(attrs),
         {:ok, label} <- compute_quick_label(destination, attrs, today),
         :ok <- ensure_no_quick_collision(destination.id, label),
         {:ok, run} <- Runs.create_quick(attrs, label),
         {:ok, _job} <- enqueue(run.id) do
      {:ok, run}
    end
  end

  defp fetch_destination(attrs) do
    case load_destination(attrs["destination_id"]) do
      nil -> {:error, quick_error(attrs, :destination_id, "does not exist")}
      destination -> {:ok, destination}
    end
  end

  defp load_destination(id) when is_binary(id) and id != "", do: Destinations.get(id)
  defp load_destination(_), do: nil

  defp compute_quick_label(destination, attrs, today) do
    case KeyBuilder.quick_label(destination.quick_archive_prefix, today, attrs["name"] || "") do
      {:ok, label} -> {:ok, label}
      {:error, :empty_slug} -> {:error, quick_error(attrs, :name, @empty_slug_message)}
    end
  end

  defp ensure_no_quick_collision(destination_id, label) do
    case Runs.quick_collision(destination_id, label) do
      nil -> :ok
      %Run{} = existing -> {:error, :collision, existing}
    end
  end

  defp quick_error(attrs, field, message) do
    %Run{}
    |> Run.quick_form_changeset(attrs)
    |> Map.put(:action, :insert)
    |> Ecto.Changeset.add_error(field, message)
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
