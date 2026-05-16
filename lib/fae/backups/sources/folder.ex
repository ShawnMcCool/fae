defmodule Fae.Backups.Sources.Folder do
  @moduledoc """
  Source adapter for a directory. No copy; the packager tars the
  directory in place. Cleanup is a no-op.

  Errors if the path is missing or is not a directory.
  """
  @behaviour Fae.Backups.Sources.Source

  @impl true
  def snapshot(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, :dir, path, fn -> :ok end}
      {:ok, %File.Stat{type: type}} -> {:error, {:not_a_directory, type}}
      {:error, reason} -> {:error, {:stat, reason}}
    end
  end
end
