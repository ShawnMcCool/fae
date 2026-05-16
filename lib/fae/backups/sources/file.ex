defmodule Fae.Backups.Sources.File do
  @moduledoc """
  Source adapter for a single regular file. No copy or snapshot; the
  pipeline reads bytes directly from the path. Cleanup is a no-op.

  Errors if the path is missing or is not a regular file (e.g. a
  directory or a broken symlink).
  """
  @behaviour Fae.Backups.Sources.Source

  @impl true
  def snapshot(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, :file, path, fn -> :ok end}
      {:ok, %File.Stat{type: type}} -> {:error, {:not_a_regular_file, type}}
      {:error, reason} -> {:error, {:stat, reason}}
    end
  end
end
