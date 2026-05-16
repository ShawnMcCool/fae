defmodule Fae.Backups.Destination do
  @moduledoc """
  A first-class, reusable backup destination. Holds the driver + the
  credentials/endpoint needed to talk to it. Jobs reference a
  destination plus a per-job prefix.

  Currently the only supported driver is `"s3"` (S3-compatible — Hetzner
  Object Storage, AWS S3, MinIO, etc.). `force_path_style` should be
  `true` for Hetzner.

  Credentials live in the SQLite DB; the DB file is mode 0600 in
  `~/.local/share/fae/` per the application's filesystem layout.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime]

  @drivers ~w(s3)

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          driver: String.t() | nil,
          endpoint_url: String.t() | nil,
          region: String.t() | nil,
          bucket: String.t() | nil,
          force_path_style: boolean(),
          access_key_id: String.t() | nil,
          secret_access_key: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "backup_destinations" do
    field :name, :string
    field :driver, :string, default: "s3"
    field :endpoint_url, :string
    field :region, :string
    field :bucket, :string
    field :force_path_style, :boolean, default: false
    field :access_key_id, :string
    field :secret_access_key, :string

    timestamps()
  end

  @required ~w(name driver endpoint_url region bucket access_key_id secret_access_key)a
  @optional ~w(force_path_style)a

  def changeset(destination, attrs) do
    destination
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:driver, @drivers)
    |> validate_format(:endpoint_url, ~r{^https?://},
      message: "must start with http:// or https://"
    )
    |> unique_constraint(:name)
  end

  @doc "Allowed driver atoms-as-strings."
  def drivers, do: @drivers
end
