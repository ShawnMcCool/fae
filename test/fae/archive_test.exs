defmodule Fae.ArchiveTest do
  use Fae.DataCase, async: false

  alias Fae.Archive
  alias Fae.Archive.Runs
  alias Fae.Storage.Destinations

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    {:ok, dest} =
      Destinations.create(%{
        name: "Dest #{System.unique_integer([:positive])}",
        driver: "s3",
        endpoint_url: "https://example.com",
        region: "us",
        bucket: "b",
        access_key_id: "k",
        secret_access_key: "s"
      })

    {:ok, run} = Runs.create(%{name: "Cam", source_path: tmp_dir, destination_id: dest.id})
    {:ok, run: run, dest: dest, source: tmp_dir}
  end

  describe "replace/2" do
    test "refuses while a sync is in flight", %{run: run, dest: dest, source: source} do
      {:ok, _} = Runs.mark_uploading(run, 1, 1)

      assert {:error, :busy} =
               Archive.replace(run.id, %{
                 name: "X",
                 source_path: source,
                 destination_id: dest.id
               })

      assert Runs.get(run.id)
    end

    test "returns not_found for a missing archive", %{dest: dest, source: source} do
      assert {:error, :not_found} =
               Archive.replace(Ecto.UUID.generate(), %{
                 name: "X",
                 source_path: source,
                 destination_id: dest.id
               })
    end

    test "replaces the archive with a fresh one", %{run: run, dest: dest, source: source} do
      assert {:ok, new} =
               Archive.replace(run.id, %{
                 name: "Cam",
                 source_path: source,
                 label: "Moved",
                 destination_id: dest.id
               })

      assert new.id != run.id
      assert new.label == "Moved"
      assert new.status == "pending"
      assert Runs.get(run.id) == nil
    end
  end

  describe "rename/2" do
    test "updates the name", %{run: run} do
      assert {:ok, renamed} = Archive.rename(run.id, %{"name" => "Renamed"})
      assert renamed.id == run.id
      assert renamed.name == "Renamed"
    end

    test "returns not_found for a missing archive" do
      assert {:error, :not_found} = Archive.rename(Ecto.UUID.generate(), %{"name" => "X"})
    end
  end
end
