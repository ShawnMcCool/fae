defmodule Fae.Dotfiles.SuggestionsTest do
  use ExUnit.Case, async: true
  alias Fae.Dotfiles.Suggestions

  test "lists entries under base not already tracked, sorted" do
    base = Path.join(System.tmp_dir!(), "sug-#{System.unique_integer([:positive])}")
    Enum.each(~w(alacritty nvim kitty), &File.mkdir_p!(Path.join(base, &1)))
    on_exit(fn -> File.rm_rf!(base) end)
    tracked = [Path.join(base, "nvim")]

    assert Suggestions.untracked_in(base, tracked) ==
             [Path.join(base, "alacritty"), Path.join(base, "kitty")]
  end
end
