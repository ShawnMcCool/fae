defmodule Fae.SelfUpdate.UpdaterTest do
  # async: false — broadcasts on the shared self_update:progress topic.
  use ExUnit.Case, async: false

  alias Fae.SelfUpdate.{UpdateChecker, Updater}
  alias Fae.Topics

  defmodule FakeDownloader do
    def run(_tarball_url, _sums_url, opts) do
      target = Keyword.fetch!(opts, :target_dir)
      filename = Keyword.fetch!(opts, :filename)
      progress_fn = Keyword.get(opts, :progress_fn, fn _, _ -> :ok end)

      File.mkdir_p!(target)
      tarball_path = Path.join(target, filename)
      File.write!(tarball_path, "fake-tarball-bytes")

      _ = progress_fn.(100, 100)
      {:ok, %{tarball_path: tarball_path, sha256: "fakesha"}}
    end
  end

  defmodule FailingDownloader do
    def run(_, _, _opts), do: {:error, :checksum_mismatch}
  end

  defmodule SyncedDownloader do
    @moduledoc """
    Sends the running downloader pid to whatever process is registered
    as `:fae_test_updater_listener` and then blocks until that listener
    sends `:proceed`. Used to pin the apply pipeline in-flight while
    the test asserts state.
    """
    def run(_, _, opts) do
      target = Keyword.fetch!(opts, :target_dir)
      filename = Keyword.fetch!(opts, :filename)
      File.mkdir_p!(target)
      tarball = Path.join(target, filename)
      File.write!(tarball, "x")

      send(:fae_test_updater_listener, {:downloader_blocked, self()})

      receive do
        :proceed -> :ok
      after
        1_000 -> raise "SyncedDownloader timed out waiting for :proceed"
      end

      {:ok, %{tarball_path: tarball, sha256: ""}}
    end
  end

  defmodule FakeStager do
    def extract(_tarball, target_dir, _opts \\ []) do
      {:ok, target_dir}
    end
  end

  defmodule FakeHandoff do
    def spawn_detached(_staged_root, _opts \\ []), do: :ok
  end

  defp tmp_staging do
    Path.join(System.tmp_dir!(), "fae-updater-staging-#{System.unique_integer()}")
  end

  defp seed_cache(version) do
    release = %{
      version: version,
      tag: "v#{version}",
      published_at: DateTime.utc_now(),
      html_url: "https://github.com/ShawnMcCool/fae/releases/tag/v#{version}",
      body: ""
    }

    UpdateChecker.cache_result({:ok, release})
    release
  end

  defp setup_updater(opts) do
    UpdateChecker.clear_cache()

    # Pick a version higher than the running app's version so the
    # cached release classifies as :update_available.
    seed_cache("99.99.99")

    staging_root = tmp_staging()
    on_exit(fn -> File.rm_rf(staging_root) end)
    on_exit(fn -> UpdateChecker.clear_cache() end)

    full_opts = Keyword.merge([name: nil, staging_root: staging_root], opts)
    pid = start_supervised!({Updater, full_opts})
    {pid, staging_root}
  end

  describe "status/1" do
    test "starts in :idle with no release" do
      {pid, _} = setup_updater([])

      assert %{phase: :idle, release: nil, error: nil} = Updater.status(pid)
    end
  end

  describe "apply_pending/1" do
    test "rejects when nothing is cached" do
      UpdateChecker.clear_cache()
      staging_root = tmp_staging()
      on_exit(fn -> File.rm_rf(staging_root) end)
      pid = start_supervised!({Updater, name: nil, staging_root: staging_root})

      assert {:error, :no_update_pending} = Updater.apply_pending(pid)
    end

    test "rejects when cached release is :up_to_date / :ahead_of_release" do
      UpdateChecker.clear_cache()
      seed_cache("0.0.1")
      staging_root = tmp_staging()
      on_exit(fn -> File.rm_rf(staging_root) end)
      on_exit(fn -> UpdateChecker.clear_cache() end)
      pid = start_supervised!({Updater, name: nil, staging_root: staging_root})

      assert {:error, :no_update_pending} = Updater.apply_pending(pid)
    end

    test "drives the pipeline to :done with fakes" do
      {pid, _} =
        setup_updater(
          downloader: FakeDownloader,
          stager: FakeStager,
          handoff: FakeHandoff
        )

      :ok = Phoenix.PubSub.subscribe(Fae.PubSub, Topics.self_update_progress())

      assert :ok = Updater.apply_pending(pid)
      assert_receive {:progress, :preparing, _}
      assert_receive {:progress, :downloading, _}, 200
      assert_receive {:progress, :extracting, _}, 200
      assert_receive {:progress, :handing_off, _}, 200
      assert_receive {:progress, :done, _}, 200
    end

    test "second apply during in-flight pipeline returns :already_running" do
      {pid, _} =
        setup_updater(
          downloader: SyncedDownloader,
          stager: FakeStager,
          handoff: FakeHandoff
        )

      Process.register(self(), :fae_test_updater_listener)

      :ok = Updater.apply_pending(pid)

      # Wait until the downloader is blocked — at that point the pipeline
      # is provably in-flight.
      assert_receive {:downloader_blocked, downloader_pid}, 200

      assert {:error, :already_running} = Updater.apply_pending(pid)

      # Let the pipeline finish so on_exit cleanup doesn't race.
      send(downloader_pid, :proceed)
    end
  end

  describe "apply failure paths" do
    test "broadcasts {:apply_failed, {:download, reason}} when the downloader fails" do
      {pid, _} =
        setup_updater(
          downloader: FailingDownloader,
          stager: FakeStager,
          handoff: FakeHandoff
        )

      :ok = Phoenix.PubSub.subscribe(Fae.PubSub, Topics.self_update_progress())

      :ok = Updater.apply_pending(pid)
      assert_receive {:apply_failed, {:download, :checksum_mismatch}}, 200
    end
  end
end
