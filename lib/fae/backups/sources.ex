defmodule Fae.Backups.Sources do
  @moduledoc """
  Dispatch from a `Fae.Backups.Job` to the right source adapter.
  """

  alias Fae.Backups.Job
  alias Fae.Backups.Sources

  @adapters %{
    "file" => Sources.File,
    "folder" => Sources.Folder,
    "sqlite" => Sources.Sqlite
  }

  @spec snapshot(Job.t()) :: Sources.Source.snapshot()
  def snapshot(%Job{source_kind: kind, source_path: path}) do
    case Map.fetch(@adapters, kind) do
      {:ok, adapter} -> adapter.snapshot(path)
      :error -> {:error, {:unknown_source_kind, kind}}
    end
  end
end
