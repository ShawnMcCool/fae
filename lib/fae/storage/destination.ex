defmodule Fae.Storage.Destination do
  @moduledoc """
  A first-class, reusable storage destination, shared by the Backups
  and Archive tools. Holds the driver + the credentials/endpoint
  needed to talk to it. Backup jobs and archive runs reference a
  destination plus their own prefix/label.

  The table is named `backup_destinations` for historical reasons (it
  predates the Archive tool); the data is destination-generic.

  Currently the only supported driver is `"s3"` (S3-compatible — Hetzner
  Object Storage, AWS S3, MinIO, etc.). `force_path_style` should be
  `true` for Hetzner.

  `path_prefix` is an optional bucket-root prefix that applies to every
  job using this destination — useful when one bucket is shared across
  multiple Fae installs or users. Leading/trailing slashes are trimmed
  on cast. The effective object key is
  `<path_prefix>/<job.prefix>/<job.slug>/<timestamp>.<ext>`; any empty
  segment is omitted.

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
          path_prefix: String.t(),
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
    field :path_prefix, :string, default: ""
    field :access_key_id, :string
    field :secret_access_key, :string

    timestamps()
  end

  @required ~w(name driver endpoint_url region bucket access_key_id secret_access_key)a
  @optional ~w(force_path_style path_prefix)a

  def changeset(destination, attrs) do
    destination
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:driver, @drivers)
    |> validate_format(:endpoint_url, ~r{^https?://},
      message: "must start with http:// or https://"
    )
    |> normalize_path_prefix()
    |> unique_constraint(:name)
  end

  defp normalize_path_prefix(changeset) do
    case get_change(changeset, :path_prefix) do
      nil ->
        changeset

      value ->
        normalized = value |> to_string() |> String.trim() |> String.trim("/")
        put_change(changeset, :path_prefix, normalized)
    end
  end

  @doc "Allowed driver atoms-as-strings."
  def drivers, do: @drivers
end
