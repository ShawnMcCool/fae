defmodule Fae.Backups.SourcesTest do
  use ExUnit.Case, async: true

  alias Fae.Backups.Job
  alias Fae.Backups.Sources
  alias Fae.Backups.Sources.{File, Folder, Sqlite}
  alias Exqlite.Sqlite3

  defp tmp_path(name) do
    Path.join(System.tmp_dir!(), "fae-test-#{Ecto.UUID.generate()}-#{name}")
  end

  describe "Sources.File" do
    test "returns :file kind for a regular file" do
      path = tmp_path("a.txt")
      Elixir.File.write!(path, "hi")

      assert {:ok, :file, ^path, cleanup} = File.snapshot(path)
      assert is_function(cleanup, 0)
      assert cleanup.() == :ok

      Elixir.File.rm!(path)
    end

    test "errors when path does not exist" do
      assert {:error, {:stat, :enoent}} = File.snapshot(tmp_path("missing"))
    end

    test "errors when path is a directory" do
      dir = tmp_path("dir")
      Elixir.File.mkdir_p!(dir)
      assert {:error, {:not_a_regular_file, :directory}} = File.snapshot(dir)
      Elixir.File.rm_rf!(dir)
    end
  end

  describe "Sources.Folder" do
    test "returns :dir kind for a directory" do
      dir = tmp_path("dir")
      Elixir.File.mkdir_p!(dir)

      assert {:ok, :dir, ^dir, cleanup} = Folder.snapshot(dir)
      assert cleanup.() == :ok

      Elixir.File.rm_rf!(dir)
    end

    test "errors when path is a file" do
      file = tmp_path("a.txt")
      Elixir.File.write!(file, "hi")
      assert {:error, {:not_a_directory, :regular}} = Folder.snapshot(file)
      Elixir.File.rm!(file)
    end

    test "errors when path does not exist" do
      assert {:error, {:stat, :enoent}} = Folder.snapshot(tmp_path("missing"))
    end
  end

  describe "Sources.Sqlite" do
    test "snapshots a live SQLite DB to a tmp file" do
      src = tmp_path("src.db")

      # Build a small DB with one row.
      {:ok, db} = Sqlite3.open(src)
      :ok = Sqlite3.execute(db, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
      :ok = Sqlite3.execute(db, "INSERT INTO t (id, name) VALUES (1, 'alice')")
      :ok = Sqlite3.close(db)

      assert {:ok, :file, tmp, cleanup} = Sqlite.snapshot(src)
      assert Elixir.File.exists?(tmp)
      refute tmp == src

      # Verify the snapshot is a real SQLite DB with the same row.
      {:ok, snap} = Sqlite3.open(tmp, mode: :readonly)
      {:ok, stmt} = Sqlite3.prepare(snap, "SELECT id, name FROM t")
      {:row, [1, "alice"]} = Sqlite3.step(snap, stmt)
      :done = Sqlite3.step(snap, stmt)
      :ok = Sqlite3.release(snap, stmt)
      :ok = Sqlite3.close(snap)

      # Cleanup removes the snapshot.
      assert cleanup.() == :ok
      refute Elixir.File.exists?(tmp)

      Elixir.File.rm!(src)
    end

    test "errors when path does not exist" do
      assert {:error, {:stat, :enoent}} = Sqlite.snapshot(tmp_path("missing"))
    end
  end

  describe "Sources.snapshot/1 dispatch" do
    test "dispatches by source_kind" do
      path = tmp_path("a.txt")
      Elixir.File.write!(path, "hi")
      job = %Job{source_kind: "file", source_path: path}
      assert {:ok, :file, ^path, _cleanup} = Sources.snapshot(job)
      Elixir.File.rm!(path)
    end

    test "errors on unknown source_kind" do
      job = %Job{source_kind: "tape", source_path: "/dev/null"}
      assert {:error, {:unknown_source_kind, "tape"}} = Sources.snapshot(job)
    end
  end
end
