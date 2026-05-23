defmodule Fae.Archive.Scanner do
  @moduledoc """
  Walks a source directory and returns its regular files as paths
  relative to the root, paired with their byte sizes.

  Symlinks are skipped — both to avoid directory loops and to keep an
  archive from silently escaping the tree the user selected. Hidden
  files (dotfiles) and empty files are included; they are real data.
  Results are sorted by relative path for deterministic processing.
  """

  @type entry :: %{relative_path: String.t(), byte_size: non_neg_integer()}

  @spec scan(String.t()) :: [entry()]
  def scan(root) do
    root = Path.expand(root)

    root
    |> walk(root)
    |> Enum.sort_by(& &1.relative_path)
  end

  defp walk(path, root) do
    case File.ls(path) do
      {:ok, names} -> Enum.flat_map(names, &entry_for(Path.join(path, &1), root))
      {:error, _reason} -> []
    end
  end

  defp entry_for(full_path, root) do
    case File.lstat(full_path) do
      {:ok, %File.Stat{type: :symlink}} -> []
      {:ok, %File.Stat{type: :directory}} -> walk(full_path, root)
      {:ok, %File.Stat{type: :regular, size: size}} -> [entry(full_path, root, size)]
      {:ok, %File.Stat{}} -> []
      {:error, _reason} -> []
    end
  end

  defp entry(full_path, root, size) do
    %{relative_path: Path.relative_to(full_path, root), byte_size: size}
  end
end
