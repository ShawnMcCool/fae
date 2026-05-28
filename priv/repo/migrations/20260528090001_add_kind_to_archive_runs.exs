defmodule Fae.Repo.Migrations.AddKindToArchiveRuns do
  use Ecto.Migration

  def change do
    # Distinguishes a standard (curated, content-dated, reconfigurable)
    # archive from a quick (one-shot, upload-dated) one. Existing rows are
    # standard; the quick path is opt-in via its own form.
    alter table(:archive_runs) do
      add :kind, :text, null: false, default: "standard"
    end
  end
end
