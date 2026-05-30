defmodule Fae.Dotfiles.Paths do
  @moduledoc "Filesystem locations for the Dotfiles bare repo + manifest."

  @manifest_relpath ".config/fae/package-list.txt"

  def git_dir, do: env!(:git_dir)
  def work_tree, do: env!(:work_tree)
  def manifest_relpath, do: @manifest_relpath
  def manifest_path, do: Path.join(work_tree(), @manifest_relpath)

  defp env!(key) do
    Application.get_env(:fae, Fae.Dotfiles, []) |> Keyword.fetch!(key)
  end
end
