defmodule Fae.SelfUpdate.StorageTest do
  use Fae.DataCase, async: true

  alias Fae.SelfUpdate.{Storage, UpdateChecker}

  setup do
    UpdateChecker.clear_cache()
    on_exit(fn -> UpdateChecker.clear_cache() end)
    :ok
  end

  defp release_fixture(version) do
    %{
      version: version,
      tag: "v#{version}",
      published_at: ~U[2026-05-16 12:00:00Z],
      html_url: "https://github.com/ShawnMcCool/fae/releases/tag/v#{version}",
      body: "Release notes for #{version}"
    }
  end

  describe "put_latest_known/2 and get_latest_known/0" do
    test "returns :none when nothing has been persisted" do
      assert Storage.get_latest_known() == :none
    end

    test "round-trips a release with its classification" do
      release = release_fixture("1.0.0")

      :ok = Storage.put_latest_known(release, :update_available)

      assert {:ok, %{release: stored, classification: :update_available}} =
               Storage.get_latest_known()

      assert stored.version == "1.0.0"
      assert stored.tag == "v1.0.0"
      assert %DateTime{} = stored.published_at
      assert stored.body == "Release notes for 1.0.0"
    end
  end

  describe "put_last_check_at/1 and get_last_check_at/0" do
    test "returns :none when no check has been recorded" do
      assert Storage.get_last_check_at() == :none
    end

    test "round-trips the timestamp" do
      at = ~U[2026-05-16 12:34:56Z]
      :ok = Storage.put_last_check_at(at)

      assert {:ok, ^at} = Storage.get_last_check_at()
    end
  end

  describe "record_check_result/1" do
    test "on success: writes both latest_known and last_check_at, populates cache" do
      release = release_fixture("9.9.9")

      assert {:ok, classification, ^release} = Storage.record_check_result({:ok, release})
      assert classification in [:update_available, :up_to_date, :ahead_of_release]

      assert {:ok, %{release: stored}} = Storage.get_latest_known()
      assert stored.version == "9.9.9"

      assert {:ok, %DateTime{}} = Storage.get_last_check_at()
      assert {:fresh, {:ok, ^release}} = UpdateChecker.cached_latest_release()
    end

    test "on error: caches the error but does NOT write the durable entries" do
      assert {:error, :not_found} = Storage.record_check_result({:error, :not_found})

      assert Storage.get_latest_known() == :none
      assert Storage.get_last_check_at() == :none
      assert {:fresh, {:error, :not_found}} = UpdateChecker.cached_latest_release()
    end
  end

  describe "hydrate_cache/0" do
    test "is a no-op when nothing has been persisted" do
      assert :ok = Storage.hydrate_cache()
      assert UpdateChecker.cached_latest_release() == :stale
    end

    test "loads the persisted release into the hot-path cache" do
      release = release_fixture("2.0.0")
      :ok = Storage.put_latest_known(release, :update_available)

      :ok = Storage.hydrate_cache()

      assert {:fresh, {:ok, cached}} = UpdateChecker.cached_latest_release()
      assert cached.version == "2.0.0"
    end
  end
end
