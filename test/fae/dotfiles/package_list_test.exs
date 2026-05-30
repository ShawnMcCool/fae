defmodule Fae.Dotfiles.PackageListTest do
  use ExUnit.Case, async: true
  alias Fae.Dotfiles.PackageList

  test "sorts package names from the command output" do
    cmd = fn "pacman", ["-Qqe"], _ -> {"git\nbat\nalacritty\n", 0} end
    assert PackageList.generate(cmd) == "alacritty\nbat\ngit"
  end

  test "write! writes to the given path" do
    target = Path.join(System.tmp_dir!(), "pl-#{System.unique_integer([:positive])}.txt")
    cmd = fn _, _, _ -> {"b\na\n", 0} end
    :ok = PackageList.write!(target, cmd)
    assert File.read!(target) == "a\nb\n"
  end
end
