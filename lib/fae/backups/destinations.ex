defmodule Fae.Backups.Destinations do
  @moduledoc """
  Context for `Fae.Backups.Destination` — first-class, reusable
  destinations referenced by backup jobs.

  Two creation paths are exposed:

    * `create/1` and `update/2` — pure persistence; never hit the
      network. Used by tests, seeds, and any internal caller that
      already trusts its input.
    * `create_with_verification/1` and `update_with_verification/2` —
      run the driver's `verify/1` (a HEAD on the bucket for S3)
      before persisting. The form behind `/backups/destinations/new`
      uses these so credentials/region/bucket-existence problems
      become inline form errors instead of cryptic Hetzner failures
      at the first backup run.
  """

  import Ecto.Query, only: [from: 2]

  alias Fae.Backups.{Destination, Drivers}
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

  @spec create_with_verification(map()) ::
          {:ok, Destination.t()} | {:error, Ecto.Changeset.t()}
  def create_with_verification(attrs) do
    %Destination{}
    |> Destination.changeset(attrs)
    |> verify_then(&Repo.insert/1)
  end

  @spec update_with_verification(Destination.t(), map()) ::
          {:ok, Destination.t()} | {:error, Ecto.Changeset.t()}
  def update_with_verification(%Destination{} = destination, attrs) do
    destination
    |> Destination.changeset(attrs)
    |> verify_then(&Repo.update/1)
  end

  @spec delete(Destination.t()) :: {:ok, Destination.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Destination{} = destination), do: Repo.delete(destination)

  @spec change(Destination.t() | %{}, map()) :: Ecto.Changeset.t()
  def change(destination \\ %Destination{}, attrs \\ %{}),
    do: Destination.changeset(destination, attrs)

  # Applies the changeset to produce a candidate struct, runs the
  # driver's verify, and either persists or returns the changeset
  # with the verify error attached to the most relevant field.
  #
  # On the error path we set `:action` on the returned changeset so
  # Phoenix's input component treats the fields as "used" and
  # renders the inline error messages.
  defp verify_then(changeset, persist_fun) do
    action = if changeset.data.id, do: :update, else: :insert

    with {:ok, draft} <- Ecto.Changeset.apply_action(changeset, action),
         :ok <- run_verify(draft) do
      persist_fun.(changeset)
    else
      {:error, %Ecto.Changeset{} = invalid_changeset} ->
        {:error, invalid_changeset}

      {:error, reason} ->
        {:error, changeset |> attach_verify_error(reason) |> Map.put(:action, action)}
    end
  end

  defp run_verify(%Destination{} = draft) do
    driver = Drivers.driver_for(draft)
    driver.verify(draft)
  end

  defp attach_verify_error(changeset, :unauthorized),
    do:
      Ecto.Changeset.add_error(
        changeset,
        :access_key_id,
        "credentials rejected by the destination (HTTP 401)"
      )

  defp attach_verify_error(changeset, :forbidden),
    do:
      Ecto.Changeset.add_error(
        changeset,
        :access_key_id,
        "credentials lack permission for this bucket (HTTP 403)"
      )

  defp attach_verify_error(changeset, :no_bucket),
    do:
      Ecto.Changeset.add_error(
        changeset,
        :bucket,
        "no bucket with this name at the endpoint (HTTP 404)"
      )

  defp attach_verify_error(changeset, {:wrong_region, nil}),
    do:
      Ecto.Changeset.add_error(
        changeset,
        :region,
        "endpoint reports the bucket is in a different region"
      )

  defp attach_verify_error(changeset, {:wrong_region, hint}),
    do:
      Ecto.Changeset.add_error(
        changeset,
        :region,
        "bucket actually lives in region '#{hint}'"
      )

  defp attach_verify_error(changeset, {:network, reason}),
    do:
      Ecto.Changeset.add_error(
        changeset,
        :endpoint_url,
        "could not reach the endpoint: #{inspect(reason)}"
      )

  defp attach_verify_error(changeset, {:s3_error, status, _body}),
    do:
      Ecto.Changeset.add_error(
        changeset,
        :endpoint_url,
        "destination returned HTTP #{status}"
      )

  defp attach_verify_error(changeset, other),
    do:
      Ecto.Changeset.add_error(
        changeset,
        :endpoint_url,
        "verification failed: #{inspect(other)}"
      )
end
