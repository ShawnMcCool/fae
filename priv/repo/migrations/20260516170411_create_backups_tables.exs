defmodule Fae.Repo.Migrations.CreateBackupsTables do
  use Ecto.Migration

  def change do
    create table(:backup_destinations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :text, null: false
      add :driver, :text, null: false
      add :endpoint_url, :text, null: false
      add :region, :text, null: false
      add :bucket, :text, null: false
      add :force_path_style, :boolean, null: false, default: false
      add :access_key_id, :text, null: false
      add :secret_access_key, :text, null: false

      timestamps()
    end

    create unique_index(:backup_destinations, [:name])

    create table(:backup_jobs, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :text, null: false
      add :slug, :text, null: false
      add :source_kind, :text, null: false
      add :source_path, :text, null: false

      add :destination_id,
          references(:backup_destinations, type: :uuid, on_delete: :restrict),
          null: false

      add :prefix, :text, null: false, default: ""
      add :package_format, :text, null: false
      add :recurrence_kind, :text, null: false
      add :time_of_day, :text
      add :day_of_week, :integer
      add :day_of_month, :integer
      add :retention_strategy, :text, null: false
      add :retention_params, :map, null: false
      add :enabled, :boolean, null: false, default: true

      timestamps()
    end

    create unique_index(:backup_jobs, [:slug])
    create index(:backup_jobs, [:destination_id])

    create table(:backup_runs, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :job_id,
          references(:backup_jobs, type: :uuid, on_delete: :delete_all),
          null: false

      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :status, :text, null: false
      add :error_message, :text
      add :object_key, :text
      add :byte_size, :bigint
      add :sha256, :text

      timestamps(updated_at: false)
    end

    create index(:backup_runs, [:job_id, :started_at])
    create index(:backup_runs, [:status])
  end
end
