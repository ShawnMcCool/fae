defmodule Fae.Repo.Migrations.AddQuickArchivePrefixToBackupDestinations do
  use Ecto.Migration

  def change do
    # Optional folder segment under the destination's path_prefix where
    # Quick Archive drops its dated folders, keeping one-shot dumps out of
    # the curated archive layout. Null = drop straight under path_prefix.
    alter table(:backup_destinations) do
      add :quick_archive_prefix, :text, null: true
    end
  end
end
