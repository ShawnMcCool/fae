defmodule Fae.Dotfiles.TopicsTest do
  use ExUnit.Case, async: true
  alias Fae.Topics

  test "topics are stable strings" do
    assert Topics.dotfiles_status() == "dotfiles:status"
    assert Topics.dotfiles_runs() == "dotfiles:runs"
  end
end
