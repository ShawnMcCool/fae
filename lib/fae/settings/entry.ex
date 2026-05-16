defmodule Fae.Settings.Entry do
  @moduledoc """
  Key/value settings entry persisted in SQLite. `value` is an arbitrary
  map; callers serialize whatever structure they want under their key.

  Used today by the self-update flow for caching the last check time
  and the latest known release. Future tools (backups, etc.) reuse the
  same table with their own key prefix.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          key: String.t() | nil,
          value: map() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "settings_entries" do
    field :key, :string
    field :value, :map

    timestamps()
  end

  def upsert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:key, :value])
    |> validate_required([:key])
  end

  def update_changeset(entry, attrs) do
    cast(entry, attrs, [:value])
  end
end
