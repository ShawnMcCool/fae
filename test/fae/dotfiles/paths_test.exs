defmodule Fae.Dotfiles.PathsTest do
  use ExUnit.Case, async: true
  alias Fae.Dotfiles.Paths

  test "reads git_dir/work_tree from app env" do
    env = Application.get_env(:fae, Fae.Dotfiles)
    assert Paths.git_dir() == Keyword.fetch!(env, :git_dir)
    assert Paths.work_tree() == Keyword.fetch!(env, :work_tree)
  end

  test "manifest lives under work_tree/.config/fae" do
    assert Paths.manifest_path() == Path.join(Paths.work_tree(), ".config/fae/package-list.txt")
    assert Paths.manifest_relpath() == ".config/fae/package-list.txt"
  end
end
