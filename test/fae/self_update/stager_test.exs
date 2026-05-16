defmodule Fae.SelfUpdate.StagerTest do
  use ExUnit.Case, async: true

  alias Fae.SelfUpdate.Stager

  # :erl_tar entry shape used by Stager: {name, type, size, mtime, mode, uid, gid}
  defp entry(name, type, size \\ 0) do
    {String.to_charlist(name), type, size, 0, 0o644, 0, 0}
  end

  describe "validate_entries/2" do
    test "accepts ordinary regular and directory entries" do
      entries = [
        entry("bin/", :directory),
        entry("bin/fae", :regular, 100),
        entry("share/systemd/fae.service", :regular, 200)
      ]

      assert :ok = Stager.validate_entries(entries, 1_000_000)
    end

    test "rejects absolute paths" do
      entries = [entry("/etc/passwd", :regular, 100)]

      assert {:error, :absolute_path} = Stager.validate_entries(entries, 1_000_000)
    end

    test "rejects parent-dir traversal segments" do
      for path <- ["../escape", "a/../b/c", "bin/../../etc/passwd"] do
        assert {:error, :path_traversal} =
                 Stager.validate_entries([entry(path, :regular, 100)], 1_000_000),
               "expected #{path} to be rejected as :path_traversal"
      end
    end

    test "rejects symlinks" do
      entries = [entry("bin/link", :symlink, 0)]

      assert {:error, :symlink} = Stager.validate_entries(entries, 1_000_000)
    end

    test "rejects non-regular special files (device, fifo, etc.)" do
      entries = [entry("dev/null", :other, 0)]

      assert {:error, :non_regular_file} = Stager.validate_entries(entries, 1_000_000)
    end

    test "rejects tarballs whose cumulative declared size exceeds max_bytes" do
      entries = [
        entry("a", :regular, 600),
        entry("b", :regular, 500)
      ]

      assert {:error, :oversized} = Stager.validate_entries(entries, 1000)
    end

    test "directory entries don't count toward the cumulative size cap" do
      entries = [
        entry("dir/", :directory),
        entry("dir/a", :regular, 400),
        entry("dir/b", :regular, 400)
      ]

      assert :ok = Stager.validate_entries(entries, 1000)
    end
  end
end
