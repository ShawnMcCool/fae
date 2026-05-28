defmodule Fae.ArchiveTest do
  use Fae.DataCase, async: false

  alias Fae.Archive
  alias Fae.Archive.Runs
  alias Fae.Storage.Destinations
  alias Fae.Topics

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

  describe "start_quick_archive/2" do
    @today ~D[2026-05-28]

    defp prefixed_destination(prefix) do
      {:ok, dest} =
        Destinations.create(%{
          name: "Dest #{System.unique_integer([:positive])}",
          driver: "s3",
          endpoint_url: "https://example.com",
          region: "us",
          bucket: "b",
          quick_archive_prefix: prefix,
          access_key_id: "k",
          secret_access_key: "s"
        })

      dest
    end

    test "creates a quick run with the dated label and enqueues it", %{
      dest: dest,
      source: source
    } do
      assert {:ok, run} =
               Archive.start_quick_archive(
                 %{
                   "name" => "My Camera Backup",
                   "source_path" => source,
                   "destination_id" => dest.id
                 },
                 @today
               )

      assert run.kind == "quick"
      assert run.name == "My Camera Backup"
      # No quick_archive_prefix on this destination → drops under the root.
      assert run.label == "2026/2026-05-28-my-camera-backup"
      # Inline Oban ran the worker against the empty dir → terminal status.
      assert Runs.get(run.id).status == "completed"
    end

    test "prepends the destination's quick_archive_prefix", %{source: source} do
      dest = prefixed_destination("archive")

      assert {:ok, run} =
               Archive.start_quick_archive(
                 %{
                   "name" => "My Camera Backup",
                   "source_path" => source,
                   "destination_id" => dest.id
                 },
                 @today
               )

      assert run.label == "archive/2026/2026-05-28-my-camera-backup"
    end

    test "broadcasts the new run on the archive:runs topic", %{dest: dest, source: source} do
      :ok = Phoenix.PubSub.subscribe(Fae.PubSub, Topics.archive_runs())

      {:ok, run} =
        Archive.start_quick_archive(
          %{"name" => "Cam", "source_path" => source, "destination_id" => dest.id},
          @today
        )

      assert_receive {:run_changed, run_id}
      assert run_id == run.id
    end

    test "rejects a label with no slug-worthy characters", %{dest: dest, source: source} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Archive.start_quick_archive(
                 %{"name" => "!!! ???", "source_path" => source, "destination_id" => dest.id},
                 @today
               )

      assert errors_on(changeset).name |> Enum.any?(&(&1 =~ "letter or number"))
      assert Runs.list() |> Enum.filter(&(&1.kind == "quick")) == []
    end

    test "rejects a missing destination with a changeset error", %{source: source} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Archive.start_quick_archive(
                 %{
                   "name" => "Cam",
                   "source_path" => source,
                   "destination_id" => Ecto.UUID.generate()
                 },
                 @today
               )

      refute changeset.valid?
      assert Map.has_key?(errors_on(changeset), :destination_id)
    end

    test "rejects a same-day same-label collision, pointing at the existing run", %{
      dest: dest,
      source: source
    } do
      attrs = %{
        "name" => "My Camera Backup",
        "source_path" => source,
        "destination_id" => dest.id
      }

      assert {:ok, first} = Archive.start_quick_archive(attrs, @today)

      assert {:error, :collision, existing} = Archive.start_quick_archive(attrs, @today)
      assert existing.id == first.id

      assert Runs.list() |> Enum.filter(&(&1.kind == "quick")) |> length() == 1
    end

    test "allows the same label on a different day", %{dest: dest, source: source} do
      attrs = %{
        "name" => "My Camera Backup",
        "source_path" => source,
        "destination_id" => dest.id
      }

      assert {:ok, _} = Archive.start_quick_archive(attrs, ~D[2026-05-28])
      assert {:ok, _} = Archive.start_quick_archive(attrs, ~D[2026-05-29])
      assert Runs.list() |> Enum.filter(&(&1.kind == "quick")) |> length() == 2
    end

    test "allows the same label on a different destination", %{source: source} do
      one = prefixed_destination("a")
      two = prefixed_destination("b")
      base = %{"name" => "My Camera Backup", "source_path" => source}

      assert {:ok, _} =
               Archive.start_quick_archive(Map.put(base, "destination_id", one.id), @today)

      assert {:ok, _} =
               Archive.start_quick_archive(Map.put(base, "destination_id", two.id), @today)
    end
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
