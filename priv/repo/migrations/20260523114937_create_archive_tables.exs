defmodule Fae.Repo.Migrations.CreateArchiveTables do
  use Ecto.Migration

  def change do
    create table(:archive_runs, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :source_path, :text, null: false
      add :label, :text, null: false, default: ""

      add :destination_id,
          references(:backup_destinations, type: :uuid, on_delete: :restrict),
          null: false

      add :status, :text, null: false
      add :total_files, :integer, null: false, default: 0
      add :total_bytes, :bigint, null: false, default: 0
      add :uploaded_files, :integer, null: false, default: 0
      add :uploaded_bytes, :bigint, null: false, default: 0
      add :failed_files, :integer, null: false, default: 0
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :error_message, :text

      timestamps()
    end

    create index(:archive_runs, [:destination_id])
    create index(:archive_runs, [:status])
    create index(:archive_runs, [:inserted_at])

    create table(:archive_items, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :run_id,
          references(:archive_runs, type: :uuid, on_delete: :delete_all),
          null: false

      add :relative_path, :text, null: false
      add :object_key, :text, null: false
      add :status, :text, null: false
      add :byte_size, :bigint
      add :sha256, :text
      add :etag, :text
      add :error_message, :text
      add :attempts, :integer, null: false, default: 0
      add :uploaded_at, :utc_datetime_usec

      timestamps()
    end

    # Re-scanning a run (e.g. resume after a crash) must not duplicate
    # items; the unique pair lets the worker insert-or-ignore.
    create unique_index(:archive_items, [:run_id, :relative_path])
    create index(:archive_items, [:run_id, :status])
  end
end
