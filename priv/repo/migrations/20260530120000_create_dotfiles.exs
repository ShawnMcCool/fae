defmodule Fae.Repo.Migrations.CreateDotfiles do
  use Ecto.Migration

  def change do
    create table(:dotfiles_config) do
      add :enabled, :boolean, null: false, default: true
      add :interval_seconds, :integer, null: false, default: 3600
      add :remote_url, :text
      add :remote_name, :text, null: false, default: "origin"
      add :branch, :text, null: false, default: "main"
      add :last_checked_at, :utc_datetime
      add :last_backup_at, :utc_datetime
      add :last_push_ok, :boolean, null: false, default: true
      add :last_push_error, :text
      add :initialized, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create table(:dotfiles_tracked_paths, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :path, :text, null: false
      add :kind, :text, null: false
      add :ignore_patterns, :text
      add :first_backed_up_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:dotfiles_tracked_paths, [:path])

    create table(:dotfiles_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :status, :text, null: false
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :files_changed, :integer
      add :files_added, :integer
      add :files_deleted, :integer
      add :packages_added, :integer
      add :packages_removed, :integer
      add :commit_sha, :text
      add :pushed, :boolean, null: false, default: false
      add :error_message, :text
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:dotfiles_runs, [:started_at])
  end
end
