defmodule Fae.Backups.Sources.Sqlite do
  @moduledoc """
  Source adapter for a SQLite database. Runs `VACUUM INTO` to a temp
  file so the snapshot is a consistent, defragmented copy of the
  source DB. Safe to use against live DBs (including Fae's own DB)
  while another process is writing.

  Cleanup removes the temp file.
  """
  @behaviour Fae.Backups.Sources.Source

  alias Exqlite.Sqlite3

  @impl true
  def snapshot(path) when is_binary(path) do
    with {:ok, _stat} <- regular_file(path),
         tmp = tmp_path(),
         {:ok, db} <- Sqlite3.open(path, mode: :readonly),
         :ok <- vacuum_into(db, tmp),
         :ok <- Sqlite3.close(db) do
      {:ok, :file, tmp,
       fn ->
         _ = File.rm(tmp)
         :ok
       end}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp regular_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, stat}
      {:ok, %File.Stat{type: type}} -> {:error, {:not_a_regular_file, type}}
      {:error, reason} -> {:error, {:stat, reason}}
    end
  end

  defp vacuum_into(db, tmp) do
    # The tmp path is an internally-generated UUID under System.tmp_dir!
    # — no user input — but we still escape single-quotes defensively
    # since VACUUM INTO doesn't accept parameter binding.
    escaped = String.replace(tmp, "'", "''")
    Sqlite3.execute(db, "VACUUM INTO '#{escaped}'")
  end

  defp tmp_path do
    Path.join(System.tmp_dir!(), "fae-backup-snapshot-#{Ecto.UUID.generate()}.db")
  end
end
