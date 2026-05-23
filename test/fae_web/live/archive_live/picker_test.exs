defmodule FaeWeb.ArchiveLive.PickerTest do
  # async: false — list_remote/2 resolves the driver via :storage_drivers
  # application env, which is global state.
  use ExUnit.Case, async: false

  import Mox

  alias Fae.Storage.Destination
  alias Fae.Storage.Drivers.DriverMock
  alias FaeWeb.ArchiveLive.Picker

  setup :verify_on_exit!

  describe "list_local/1" do
    @tag :tmp_dir
    test "returns sorted sub-directory names, excluding files", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join(tmp, "b"))
      File.mkdir_p!(Path.join(tmp, "a"))
      File.write!(Path.join(tmp, "file.txt"), "x")

      assert {:ok, %{folders: ["a", "b"]}} = Picker.list_local(tmp)
    end

    test "errors on a missing path" do
      assert {:error, _} = Picker.list_local("/no/such/dir/anywhere")
    end
  end

  describe "path helpers" do
    test "remote_join" do
      assert Picker.remote_join("", "a") == "a"
      assert Picker.remote_join("a", "b") == "a/b"
    end

    test "remote_parent" do
      assert Picker.remote_parent("a/b/c") == "a/b"
      assert Picker.remote_parent("a") == ""
      assert Picker.remote_parent("") == ""
    end

    test "remote_s3_prefix joins the destination prefix and relative path" do
      assert Picker.remote_s3_prefix(%Destination{path_prefix: "Family"}, "") == "Family/"

      assert Picker.remote_s3_prefix(%Destination{path_prefix: "Family"}, "Pics") ==
               "Family/Pics/"

      assert Picker.remote_s3_prefix(%Destination{path_prefix: ""}, "") == ""
      assert Picker.remote_s3_prefix(%Destination{path_prefix: ""}, "Pics") == "Pics/"
    end
  end

  describe "list_remote/2" do
    setup do
      Application.put_env(:fae, :storage_drivers, %{"s3" => DriverMock})
      on_exit(fn -> Application.delete_env(:fae, :storage_drivers) end)
      :ok
    end

    test "strips the current prefix down to leaf folder names, sorted" do
      dest = %Destination{driver: "s3", path_prefix: "Family"}

      expect(DriverMock, :list_prefixes, fn ^dest, "Family/" ->
        {:ok, %{prefixes: ["Family/Pictures Videos/", "Family/Documents/"], keys: []}}
      end)

      assert {:ok, %{folders: ["Documents", "Pictures Videos"]}} = Picker.list_remote(dest, "")
    end

    test "propagates driver errors" do
      dest = %Destination{driver: "s3", path_prefix: ""}
      expect(DriverMock, :list_prefixes, fn ^dest, "" -> {:error, :forbidden} end)
      assert {:error, :forbidden} = Picker.list_remote(dest, "")
    end
  end
end
