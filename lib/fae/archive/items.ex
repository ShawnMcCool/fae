defmodule Fae.Archive.Items do
  @moduledoc """
  Context for `Fae.Archive.Item` — the per-file durable records of an
  archive run. Bulk scan insertion is idempotent so a resumed run skips
  files it already uploaded.
  """
  import Ecto.Query, only: [from: 2]

  alias Fae.Archive.Item
  alias Fae.Repo

  @error_message_limit 4096

  @doc """
  Bulk-inserts scanned entries as pending items. Idempotent via the
  `(run_id, relative_path)` unique index: re-scanning a run inserts only
  entries not already present, leaving uploaded items untouched. Returns
  the number of rows newly inserted.

  Each entry is a map with `:relative_path`, `:object_key`, `:byte_size`.
  """
  @spec insert_scanned(Ecto.UUID.t(), [map()]) :: non_neg_integer()
  def insert_scanned(run_id, entries) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(entries, fn entry ->
        %{
          id: Ecto.UUID.generate(),
          run_id: run_id,
          relative_path: entry.relative_path,
          object_key: entry.object_key,
          byte_size: entry.byte_size,
          status: "pending",
          attempts: 0,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} =
      Repo.insert_all(Item, rows,
        on_conflict: :nothing,
        conflict_target: [:run_id, :relative_path]
      )

    count
  end

  @doc "Items still awaiting upload for a run, oldest path first."
  @spec pending_for_run(Ecto.UUID.t()) :: [Item.t()]
  def pending_for_run(run_id) do
    Repo.all(
      from i in Item,
        where: i.run_id == ^run_id and i.status == "pending",
        order_by: [asc: i.relative_path]
    )
  end

  @doc "All items for a run (for the detail page), oldest path first."
  @spec list_for_run(Ecto.UUID.t()) :: [Item.t()]
  def list_for_run(run_id) do
    Repo.all(from i in Item, where: i.run_id == ^run_id, order_by: [asc: i.relative_path])
  end

  @spec record_uploaded(Item.t(), %{
          byte_size: non_neg_integer(),
          sha256: String.t(),
          etag: String.t()
        }) :: {:ok, Item.t()} | {:error, Ecto.Changeset.t()}
  def record_uploaded(%Item{} = item, %{byte_size: byte_size, sha256: sha256, etag: etag}) do
    item
    |> Ecto.Changeset.change(%{
      status: "uploaded",
      byte_size: byte_size,
      sha256: sha256,
      etag: etag,
      uploaded_at: DateTime.utc_now(),
      attempts: item.attempts + 1,
      error_message: nil
    })
    |> Repo.update()
  end

  @spec record_failed(Item.t(), term()) :: {:ok, Item.t()} | {:error, Ecto.Changeset.t()}
  def record_failed(%Item{} = item, message) do
    item
    |> Ecto.Changeset.change(%{
      status: "failed",
      error_message: truncate(message),
      attempts: item.attempts + 1
    })
    |> Repo.update()
  end

  @doc "Resets failed items back to pending for a retry. Returns the count reset."
  @spec reset_failed(Ecto.UUID.t()) :: non_neg_integer()
  def reset_failed(run_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Repo.update_all(
        from(i in Item, where: i.run_id == ^run_id and i.status == "failed"),
        set: [status: "pending", error_message: nil, updated_at: now]
      )

    count
  end

  @doc "Aggregate tallies used to finalize a run's row."
  @spec counts_for_run(Ecto.UUID.t()) :: %{
          uploaded_files: non_neg_integer(),
          uploaded_bytes: non_neg_integer(),
          failed_files: non_neg_integer()
        }
  def counts_for_run(run_id) do
    base = from i in Item, where: i.run_id == ^run_id

    %{
      uploaded_files: Repo.aggregate(from(i in base, where: i.status == "uploaded"), :count, :id),
      uploaded_bytes:
        Repo.aggregate(from(i in base, where: i.status == "uploaded"), :sum, :byte_size) || 0,
      failed_files: Repo.aggregate(from(i in base, where: i.status == "failed"), :count, :id)
    }
  end

  defp truncate(nil), do: nil

  defp truncate(message) when is_binary(message),
    do: String.slice(message, 0, @error_message_limit)

  defp truncate(other), do: other |> inspect() |> String.slice(0, @error_message_limit)
end
