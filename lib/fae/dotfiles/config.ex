defmodule Fae.Dotfiles.Config do
  @moduledoc "Singleton config row (id = 1) for the Dotfiles tool."
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "dotfiles_config" do
    field :enabled, :boolean, default: true
    field :interval_seconds, :integer, default: 3600
    field :remote_url, :string
    field :remote_name, :string, default: "origin"
    field :branch, :string, default: "main"
    field :last_checked_at, :utc_datetime
    field :last_backup_at, :utc_datetime
    field :last_push_ok, :boolean, default: true
    field :last_push_error, :string
    field :initialized, :boolean, default: false
    timestamps()
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :enabled,
      :interval_seconds,
      :remote_url,
      :remote_name,
      :branch,
      :last_checked_at,
      :last_backup_at,
      :last_push_ok,
      :last_push_error,
      :initialized
    ])
    |> validate_number(:interval_seconds, greater_than_or_equal_to: 300)
  end
end
