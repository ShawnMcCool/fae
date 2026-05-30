defmodule Fae.Dotfiles.TrackedPath do
  @moduledoc "A curated path tracked for backup (folder or file)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime]
  @kinds ~w(directory file)

  @type t :: %__MODULE__{}

  schema "dotfiles_tracked_paths" do
    field :path, :string
    field :kind, :string
    field :ignore_patterns, :string
    field :first_backed_up_at, :utc_datetime
    timestamps()
  end

  def changeset(tracked, attrs) do
    tracked
    |> cast(attrs, [:path, :kind, :ignore_patterns, :first_backed_up_at])
    |> validate_required([:path, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint(:path)
  end

  def kinds, do: @kinds
end
