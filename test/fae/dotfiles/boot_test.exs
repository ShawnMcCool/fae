defmodule Fae.Dotfiles.BootTest do
  use ExUnit.Case, async: false

  test "boot! is a no-op when the scheduler is disabled (test env)" do
    assert Fae.Dotfiles.boot!() == :ok
  end
end
