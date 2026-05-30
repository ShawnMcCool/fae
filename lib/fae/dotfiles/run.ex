defmodule Fae.Dotfiles.Run do
  @moduledoc "One execution of the dotfiles backup cycle."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime, updated_at: false]
  @statuses ~w(running success no_changes error)

  schema "dotfiles_runs" do
    field :status, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :files_changed, :integer
    field :files_added, :integer
    field :files_deleted, :integer
    field :packages_added, :integer
    field :packages_removed, :integer
    field :commit_sha, :string
    field :pushed, :boolean, default: false
    field :error_message, :string
    timestamps()
  end

  def start_changeset(run, attrs) do
    run
    |> cast(attrs, [:started_at, :status])
    |> validate_required([:started_at, :status])
    |> validate_inclusion(:status, @statuses)
  end

  def finish_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :finished_at,
      :status,
      :files_changed,
      :files_added,
      :files_deleted,
      :packages_added,
      :packages_removed,
      :commit_sha,
      :pushed,
      :error_message
    ])
    |> validate_required([:finished_at, :status])
    |> validate_inclusion(:status, @statuses)
  end

  def statuses, do: @statuses
end
