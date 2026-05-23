defmodule FaeWeb.PathBrowser.SourceTest do
  # async: false — list_remote/3 resolves the driver via :storage_drivers
  # application env, which is global state.
  use ExUnit.Case, async: false

  import Mox

  alias Fae.Storage.Destination
  alias Fae.Storage.Drivers.DriverMock
  alias FaeWeb.PathBrowser.Source

  setup :verify_on_exit!

  describe "list/2 local" do
    @tag :tmp_dir
    test "folders sorted; files hidden when show_files? is false", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join(tmp, "b"))
      File.mkdir_p!(Path.join(tmp, "a"))
      File.write!(Path.join(tmp, "file.txt"), "xy")

      assert {:ok, %{folders: ["a", "b"], files: []}} = Source.list({:local, tmp}, false)
    end

    @tag :tmp_dir
    test "files include size and last-modified when show_files? is true", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join(tmp, "d"))
      File.write!(Path.join(tmp, "file.txt"), "xy")

      assert {:ok, %{folders: ["d"], files: [file]}} = Source.list({:local, tmp}, true)
      assert file.name == "file.txt"
      assert file.size == 2
      assert %DateTime{} = file.last_modified
    end

    test "errors on a missing path" do
      assert {:error, _} = Source.list({:local, "/no/such/dir/anywhere"}, false)
    end
  end

  describe "path helpers" do
    test "down/up for local and remote" do
      assert Source.down(:local, "/a", "b") == "/a/b"
      assert Source.down(:remote, "", "a") == "a"
      assert Source.down(:remote, "a", "b") == "a/b"
      assert Source.up(:local, "/a/b") == "/a"
      assert Source.up(:remote, "a/b/c") == "a/b"
      assert Source.up(:remote, "a") == ""
    end

    test "location_label" do
      assert Source.location_label(:local, "/a/b") == "/a/b"
      assert Source.location_label(:remote, "") == "(top level)"
      assert Source.location_label(:remote, "a/b") == "a/b"
    end

    test "remote_s3_prefix joins the destination prefix and relative path" do
      assert Source.remote_s3_prefix(%Destination{path_prefix: "Family"}, "") == "Family/"

      assert Source.remote_s3_prefix(%Destination{path_prefix: "Family"}, "Pics") ==
               "Family/Pics/"

      assert Source.remote_s3_prefix(%Destination{path_prefix: ""}, "") == ""
      assert Source.remote_s3_prefix(%Destination{path_prefix: ""}, "Pics") == "Pics/"
    end

    test "relativize strips the current prefix to leaf names" do
      listing = %{
        prefixes: ["Family/Pictures Videos/", "Family/Documents/"],
        files: [%{key: "Family/note.txt", size: 5, last_modified: ~U[2026-05-01 00:00:00Z]}]
      }

      assert %{folders: ["Documents", "Pictures Videos"], files: [file]} =
               Source.relativize(listing, "Family/", true)

      assert file.name == "note.txt"
      assert file.size == 5

      assert %{files: []} = Source.relativize(listing, "Family/", false)
    end
  end

  describe "list/2 remote" do
    setup do
      Application.put_env(:fae, :storage_drivers, %{"s3" => DriverMock})
      on_exit(fn -> Application.delete_env(:fae, :storage_drivers) end)
      :ok
    end

    test "maps driver listing to leaf folder names, sorted" do
      dest = %Destination{driver: "s3", path_prefix: "Family"}

      expect(DriverMock, :list_prefixes, fn ^dest, "Family/" ->
        {:ok, %{prefixes: ["Family/Pictures Videos/", "Family/Documents/"], files: []}}
      end)

      assert {:ok, %{folders: ["Documents", "Pictures Videos"]}} =
               Source.list({:remote, dest, ""}, false)
    end

    test "propagates driver errors" do
      dest = %Destination{driver: "s3", path_prefix: ""}
      expect(DriverMock, :list_prefixes, fn ^dest, "" -> {:error, :forbidden} end)
      assert {:error, :forbidden} = Source.list({:remote, dest, ""}, false)
    end
  end
end
