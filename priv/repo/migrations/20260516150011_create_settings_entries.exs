defmodule Fae.Repo.Migrations.CreateSettingsEntries do
  use Ecto.Migration

  def change do
    create table(:settings_entries, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :key, :text, null: false
      add :value, :map

      timestamps()
    end

    create unique_index(:settings_entries, [:key])
  end
end
