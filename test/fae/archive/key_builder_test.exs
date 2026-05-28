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

  describe "slugify/1" do
    test "lowercases and hyphenates a plain label" do
      assert KeyBuilder.slugify("My Camera Backup") == {:ok, "my-camera-backup"}
    end

    test "strips diacritics to ASCII" do
      assert KeyBuilder.slugify("Événement Crèche") == {:ok, "evenement-creche"}
    end

    test "collapses runs of non-alphanumerics into a single hyphen" do
      assert KeyBuilder.slugify("a  --  b__c") == {:ok, "a-b-c"}
    end

    test "trims leading and trailing separators" do
      assert KeyBuilder.slugify("  !My Stuff!  ") == {:ok, "my-stuff"}
    end

    test "keeps digits" do
      assert KeyBuilder.slugify("Trip 2024 v2") == {:ok, "trip-2024-v2"}
    end

    test "rejects a label with nothing slug-worthy" do
      assert KeyBuilder.slugify("   ") == {:error, :empty_slug}
      assert KeyBuilder.slugify("!!! ??? ---") == {:error, :empty_slug}
    end
  end

  describe "quick_label/3" do
    test "composes prefix, year, and dated slug" do
      assert KeyBuilder.quick_label("archive", ~D[2026-05-28], "My Camera Backup") ==
               {:ok, "archive/2026/2026-05-28-my-camera-backup"}
    end

    test "omits an empty or nil prefix" do
      assert KeyBuilder.quick_label("", ~D[2026-05-28], "Cam") ==
               {:ok, "2026/2026-05-28-cam"}

      assert KeyBuilder.quick_label(nil, ~D[2026-05-28], "Cam") ==
               {:ok, "2026/2026-05-28-cam"}
    end

    test "trims and strips slashes from the prefix" do
      assert KeyBuilder.quick_label("  /Family Backups/  ", ~D[2026-01-02], "Cam") ==
               {:ok, "Family Backups/2026/2026-01-02-cam"}
    end

    test "supports a nested prefix" do
      assert KeyBuilder.quick_label("a/b", ~D[2026-12-31], "Cam") ==
               {:ok, "a/b/2026/2026-12-31-cam"}
    end

    test "propagates an empty-slug rejection" do
      assert KeyBuilder.quick_label("archive", ~D[2026-05-28], "!!!") ==
               {:error, :empty_slug}
    end
  end
end
