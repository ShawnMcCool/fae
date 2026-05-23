defmodule Fae.Archive.Runs do
  @moduledoc """
  Context for `Fae.Archive.Run` — create archive runs from user input
  and drive their lifecycle (scanning → uploading → completed/partial/
  failed). Every mutation broadcasts on the `archive:runs` topic so
  LiveViews refresh in real time.
  """
  import Ecto.Query, only: [from: 2]

  alias Fae.Archive.Run
  alias Fae.Repo
  alias Fae.Topics

  @error_message_limit 4096

  @spec list() :: [Run.t()]
  def list do
    Repo.all(from r in Run, order_by: [desc: r.inserted_at])
    |> Repo.preload(:destination)
  end

  @doc "Runs left in a non-terminal state — re-enqueued on app boot."
  @spec resumable() :: [Run.t()]
  def resumable do
    Repo.all(from r in Run, where: r.status in ["pending", "scanning", "uploading"])
    |> Repo.preload(:destination)
  end

  @spec get(Ecto.UUID.t()) :: Run.t() | nil
  def get(id), do: Run |> Repo.get(id) |> preload_destination()

  @spec get!(Ecto.UUID.t()) :: Run.t()
  def get!(id), do: Run |> Repo.get!(id) |> Repo.preload(:destination)

  @spec change(Run.t(), map()) :: Ecto.Changeset.t()
  def change(run \\ %Run{}, attrs \\ %{}), do: Run.create_changeset(run, attrs)

  @spec delete(Run.t()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Run{} = run) do
    with {:ok, deleted} <- Repo.delete(run) do
      broadcast_changed(deleted.id)
      {:ok, deleted}
    end
  end

  @spec create(map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    with {:ok, run} <- %Run{} |> Run.create_changeset(attrs) |> Repo.insert() do
      broadcast_changed(run.id)
      {:ok, run}
    end
  end

  @spec rename_change(Run.t(), map()) :: Ecto.Changeset.t()
  def rename_change(run, attrs \\ %{}), do: Run.rename_changeset(run, attrs)

  @doc "In-place, non-destructive rename (the `name` only)."
  @spec rename(Run.t(), map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def rename(%Run{} = run, attrs) do
    with {:ok, updated} <- run |> Run.rename_changeset(attrs) |> Repo.update() do
      broadcast_changed(updated.id)
      {:ok, updated}
    end
  end

  @doc """
  Replaces a run with a new one built from `attrs`, atomically: the new
  run is inserted fresh (no item history) and the old run is deleted (its
  items cascade away via the FK). Bucket objects are never touched — if
  the source / remote folder / destination changed, the next sync uploads
  into the new location and the old objects simply remain. Backs the
  "Reconfigure" flow.
  """
  @spec replace(Run.t(), map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def replace(%Run{} = old, attrs) do
    result =
      Repo.transaction(fn ->
        with {:ok, new_run} <- %Run{} |> Run.create_changeset(attrs) |> Repo.insert(),
             {:ok, _deleted} <- Repo.delete(old) do
          new_run
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, new_run} ->
        broadcast_changed(old.id)
        broadcast_changed(new_run.id)
        {:ok, new_run}

      {:error, _changeset} = error ->
        error
    end
  end

  @spec mark_scanning(Run.t()) :: {:ok, Run.t()}
  def mark_scanning(%Run{} = run) do
    update_run(run, %{status: "scanning", started_at: DateTime.utc_now()})
  end

  @spec mark_uploading(Run.t(), non_neg_integer(), non_neg_integer()) :: {:ok, Run.t()}
  def mark_uploading(%Run{} = run, total_files, total_bytes) do
    update_run(run, %{status: "uploading", total_files: total_files, total_bytes: total_bytes})
  end

  @doc """
  Records the final tally and sets the terminal status — `completed`
  when nothing failed, `partial` otherwise.
  """
  @spec finalize(Run.t(), %{
          uploaded_files: non_neg_integer(),
          uploaded_bytes: non_neg_integer(),
          failed_files: non_neg_integer()
        }) :: {:ok, Run.t()}
  def finalize(%Run{} = run, %{
        uploaded_files: uploaded_files,
        uploaded_bytes: uploaded_bytes,
        failed_files: failed_files
      }) do
    status = if failed_files == 0, do: "completed", else: "partial"

    {:ok, updated} =
      update_run(run, %{
        status: status,
        uploaded_files: uploaded_files,
        uploaded_bytes: uploaded_bytes,
        failed_files: failed_files,
        finished_at: DateTime.utc_now()
      })

    broadcast_finished(updated.id, String.to_atom(status))
    {:ok, updated}
  end

  @doc "Marks a run failed wholesale (e.g. the scan itself errored)."
  @spec mark_failed(Run.t(), term()) :: {:ok, Run.t()}
  def mark_failed(%Run{} = run, message) do
    {:ok, updated} =
      update_run(run, %{
        status: "failed",
        error_message: truncate(message),
        finished_at: DateTime.utc_now()
      })

    broadcast_finished(updated.id, :failed)
    {:ok, updated}
  end

  defp update_run(run, attrs) do
    with {:ok, updated} <- run |> Ecto.Changeset.change(attrs) |> Repo.update() do
      broadcast_changed(updated.id)
      {:ok, updated}
    end
  end

  defp preload_destination(nil), do: nil
  defp preload_destination(%Run{} = run), do: Repo.preload(run, :destination)

  defp truncate(nil), do: nil

  defp truncate(message) when is_binary(message),
    do: String.slice(message, 0, @error_message_limit)

  defp truncate(other), do: other |> inspect() |> String.slice(0, @error_message_limit)

  defp broadcast_changed(run_id), do: broadcast({:run_changed, run_id})
  defp broadcast_finished(run_id, status), do: broadcast({:run_finished, run_id, status})

  defp broadcast(message),
    do: Phoenix.PubSub.broadcast(Fae.PubSub, Topics.archive_runs(), message)
end
