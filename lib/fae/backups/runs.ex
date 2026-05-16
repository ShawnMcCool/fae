defmodule Fae.Backups.Runs do
  @moduledoc """
  Context for `Fae.Backups.Run` — the durable history of backup
  attempts. The run pipeline writes start/finish records here; the
  LiveView surface reads from here.

  Writes do **not** broadcast — `Fae.Backups.RunPipeline` broadcasts
  lifecycle events directly on `backups:runs` so callers see a single
  source-of-truth message stream rather than racing DB writes against
  PubSub publishes.
  """

  import Ecto.Query, only: [from: 2]

  alias Fae.Backups.Run
  alias Fae.Repo

  @spec list_recent(Ecto.UUID.t(), pos_integer()) :: [Run.t()]
  def list_recent(job_id, limit \\ 50) do
    Repo.all(
      from r in Run,
        where: r.job_id == ^job_id,
        order_by: [desc: r.started_at],
        limit: ^limit
    )
  end

  @spec last(Ecto.UUID.t()) :: Run.t() | nil
  def last(job_id) do
    Repo.one(
      from r in Run,
        where: r.job_id == ^job_id,
        order_by: [desc: r.started_at],
        limit: 1
    )
  end

  @spec get!(Ecto.UUID.t()) :: Run.t()
  def get!(id), do: Repo.get!(Run, id)

  @spec start(Ecto.UUID.t(), DateTime.t()) ::
          {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def start(job_id, started_at) do
    %Run{}
    |> Run.start_changeset(%{job_id: job_id, started_at: started_at, status: "running"})
    |> Repo.insert()
  end

  @spec finish(Run.t(), map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def finish(%Run{} = run, attrs) do
    run
    |> Run.finish_changeset(attrs)
    |> Repo.update()
  end

  @spec record_skipped(Ecto.UUID.t(), atom(), DateTime.t()) ::
          {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def record_skipped(job_id, reason, now) do
    %Run{}
    |> Run.start_changeset(%{job_id: job_id, started_at: now, status: "skipped"})
    |> Ecto.Changeset.put_change(:finished_at, now)
    |> Ecto.Changeset.put_change(:error_message, "skipped: #{reason}")
    |> Repo.insert()
  end
end
