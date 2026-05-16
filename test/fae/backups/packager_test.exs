defmodule Fae.Backups.PackagerTest do
  use ExUnit.Case, async: true

  alias Fae.Backups.Packager

  defp tmp(name), do: Path.join(System.tmp_dir!(), "fae-test-#{Ecto.UUID.generate()}-#{name}")

  describe "as_is" do
    test "passes through a file path and preserves extension" do
      path = tmp("a.db")
      File.write!(path, "data")

      assert {:ok, ^path, "db", cleanup} = Packager.package(:file, path, "as_is")
      assert cleanup.() == :ok
      File.rm!(path)
    end

    test "uses 'bin' when the file has no extension" do
      path = tmp("noext")
      File.write!(path, "data")

      assert {:ok, _path, "bin", _cleanup} = Packager.package(:file, path, "as_is")
      File.rm!(path)
    end

    test "rejects :dir with as_is" do
      assert {:error, :folder_requires_tar_gz} = Packager.package(:dir, "/tmp", "as_is")
    end
  end

  describe "tar_gz" do
    test "packages a file into a .tar.gz" do
      path = tmp("a.db")
      File.write!(path, "hello world")

      assert {:ok, archive, "tar.gz", cleanup} = Packager.package(:file, path, "tar_gz")
      assert File.exists?(archive)
      assert byte_size(File.read!(archive)) > 0

      # Confirm it's actually a gzip stream by reading the magic bytes.
      <<0x1F, 0x8B, _::binary>> = File.read!(archive)

      cleanup.()
      refute File.exists?(archive)
      File.rm!(path)
    end

    test "packages a directory into a .tar.gz" do
      dir = tmp("dir")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "a.txt"), "a")
      File.write!(Path.join(dir, "b.txt"), "b")

      assert {:ok, archive, "tar.gz", cleanup} = Packager.package(:dir, dir, "tar_gz")
      assert File.exists?(archive)
      <<0x1F, 0x8B, _::binary>> = File.read!(archive)

      cleanup.()
      File.rm_rf!(dir)
    end

    test "errors if the source path doesn't exist" do
      assert {:error, {:tar_failed, _code, _output}} =
               Packager.package(:file, tmp("missing"), "tar_gz")
    end
  end

  test "errors on unsupported format" do
    assert {:error, {:unsupported_packaging, :file, "zip"}} =
             Packager.package(:file, "/tmp/x", "zip")
  end
end
