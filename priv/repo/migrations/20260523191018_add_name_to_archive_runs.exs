defmodule Fae.Repo.Migrations.AddNameToArchiveRuns do
  use Ecto.Migration

  def change do
    # Friendly name for an archive, distinct from `label` (the remote
    # folder segment of the object key). Default "" for any pre-existing
    # rows; new archives require it via the changeset.
    alter table(:archive_runs) do
      add :name, :text, null: false, default: ""
    end
  end
end
