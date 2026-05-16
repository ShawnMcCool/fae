defmodule Fae.Repo.Migrations.AddPathPrefixToBackupDestinations do
  use Ecto.Migration

  def change do
    alter table(:backup_destinations) do
      add :path_prefix, :text, null: false, default: ""
    end
  end
end
