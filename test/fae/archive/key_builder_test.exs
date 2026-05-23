defmodule Fae.Archive.KeyBuilderTest do
  use ExUnit.Case, async: true

  alias Fae.Archive.KeyBuilder

  test "joins prefix, label, and relative path (the user's real layout)" do
    assert KeyBuilder.build(
             "Family Backups (IMPORTANT)",
             "Pictures Videos",
             "2004/2004-04-15 family reunion/IMG.jpg"
           ) ==
             "Family Backups (IMPORTANT)/Pictures Videos/2004/2004-04-15 family reunion/IMG.jpg"
  end

  test "omits an empty prefix" do
    assert KeyBuilder.build("", "Pics", "a/b.jpg") == "Pics/a/b.jpg"
  end

  test "omits an empty label" do
    assert KeyBuilder.build("root", "", "a/b.jpg") == "root/a/b.jpg"
  end

  test "with neither prefix nor label, returns the relative path" do
    assert KeyBuilder.build("", "", "a/b.jpg") == "a/b.jpg"
  end

  test "treats nil prefix/label as empty" do
    assert KeyBuilder.build(nil, nil, "a.jpg") == "a.jpg"
  end

  test "trims surrounding slashes and whitespace on prefix and label" do
    assert KeyBuilder.build("/root/", "  Pics  ", "a.jpg") == "root/Pics/a.jpg"
  end

  test "preserves internal structure and filename whitespace in the relative path" do
    assert KeyBuilder.build("p", "l", "dir/ spaced name .jpg") == "p/l/dir/ spaced name .jpg"
  end

  test "strips a leading slash from the relative path" do
    assert KeyBuilder.build("p", "l", "/a/b.jpg") == "p/l/a/b.jpg"
  end
end
