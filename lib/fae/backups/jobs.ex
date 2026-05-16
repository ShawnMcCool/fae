defmodule Fae.Backups.Jobs do
  @moduledoc """
  Context for `Fae.Backups.Job`. Writes broadcast
  `{:job_changed, job_id}` on `Fae.Topics.backups_jobs/0`. The Oban
  scheduling glue (Phase G) listens on this topic to reschedule the
  job's next run when its recurrence changes.

  A delete broadcasts `{:job_changed, job_id}` with the now-deleted
  id so consumers can drop their cached state for it.
  """

  import Ecto.Query, only: [from: 2]

  alias Fae.Backups.Job
  alias Fae.Repo
  alias Fae.Topics

  @spec list() :: [Job.t()]
  def list do
    Repo.all(from j in Job, order_by: [asc: j.name], preload: [:destination])
  end

  @spec list_enabled() :: [Job.t()]
  def list_enabled do
    Repo.all(
      from j in Job, where: j.enabled == true, order_by: [asc: j.name], preload: [:destination]
    )
  end

  @spec get(Ecto.UUID.t()) :: Job.t() | nil
  def get(id) do
    case Repo.get(Job, id) do
      nil -> nil
      job -> Repo.preload(job, :destination)
    end
  end

  @spec get!(Ecto.UUID.t()) :: Job.t()
  def get!(id) do
    Job
    |> Repo.get!(id)
    |> Repo.preload(:destination)
  end

  @spec get_by_slug(String.t()) :: Job.t() | nil
  def get_by_slug(slug) do
    case Repo.get_by(Job, slug: slug) do
      nil -> nil
      job -> Repo.preload(job, :destination)
    end
  end

  @spec create(map()) :: {:ok, Job.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Job{}
    |> Job.changeset(attrs)
    |> Repo.insert()
    |> broadcast_change()
  end

  @spec update(Job.t(), map()) :: {:ok, Job.t()} | {:error, Ecto.Changeset.t()}
  def update(%Job{} = job, attrs) do
    job
    |> Job.changeset(attrs)
    |> Repo.update()
    |> broadcast_change()
  end

  @spec delete(Job.t()) :: {:ok, Job.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Job{} = job) do
    case Repo.delete(job) do
      {:ok, deleted} = result ->
        broadcast(deleted.id)
        result

      error ->
        error
    end
  end

  @spec change(Job.t() | %{}, map()) :: Ecto.Changeset.t()
  def change(job \\ %Job{}, attrs \\ %{}), do: Job.changeset(job, attrs)

  defp broadcast_change({:ok, %Job{id: id}} = result) do
    broadcast(id)
    result
  end

  defp broadcast_change(other), do: other

  defp broadcast(job_id) do
    Phoenix.PubSub.broadcast(Fae.PubSub, Topics.backups_jobs(), {:job_changed, job_id})
  end
end
