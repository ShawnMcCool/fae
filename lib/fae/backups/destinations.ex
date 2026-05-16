defmodule Fae.Backups.Destinations do
  @moduledoc """
  Context for `Fae.Backups.Destination` — first-class, reusable
  destinations referenced by backup jobs.
  """

  import Ecto.Query, only: [from: 2]

  alias Fae.Backups.Destination
  alias Fae.Repo

  @spec list() :: [Destination.t()]
  def list do
    Repo.all(from d in Destination, order_by: [asc: d.name])
  end

  @spec get(Ecto.UUID.t()) :: Destination.t() | nil
  def get(id), do: Repo.get(Destination, id)

  @spec get!(Ecto.UUID.t()) :: Destination.t()
  def get!(id), do: Repo.get!(Destination, id)

  @spec create(map()) :: {:ok, Destination.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Destination{}
    |> Destination.changeset(attrs)
    |> Repo.insert()
  end

  @spec update(Destination.t(), map()) ::
          {:ok, Destination.t()} | {:error, Ecto.Changeset.t()}
  def update(%Destination{} = destination, attrs) do
    destination
    |> Destination.changeset(attrs)
    |> Repo.update()
  end

  @spec delete(Destination.t()) :: {:ok, Destination.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Destination{} = destination), do: Repo.delete(destination)

  @spec change(Destination.t() | %{}, map()) :: Ecto.Changeset.t()
  def change(destination \\ %Destination{}, attrs \\ %{}),
    do: Destination.changeset(destination, attrs)
end
