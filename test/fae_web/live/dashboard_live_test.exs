defmodule FaeWeb.DashboardLiveTest do
  # async: false — DashboardLive subscribes to shared PubSub topics
  # (system_status, backups:runs, backups:jobs, self_update:*). Other
  # tests broadcasting on the same topics would cross-contaminate.
  use FaeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fae.Backups.{Jobs, Runs}
  alias Fae.Dotfiles.{Configs, TrackedPaths}
  alias Fae.Storage.Destinations
  alias Fae.Topics

  describe "GET /" do
    test "renders every dashboard section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#health-banner")
      assert has_element?(view, "#system-section")
      assert has_element?(view, "#jobs-section")
      assert has_element?(view, "#activity-section")
      assert has_element?(view, "#destinations-section")
      assert has_element?(view, "#dotfiles-section")
    end

    test "shows the dotfiles tracked-path count", %{conn: conn} do
      {:ok, _} = Configs.update(%{enabled: true})
      home = System.tmp_dir!()
      File.mkdir_p!(Path.join(home, ".config/nvim"))
      {:ok, _} = TrackedPaths.add(%{path: Path.join(home, ".config/nvim"), kind: "directory"})

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#dotfiles-tracked-count", "1")
    end

    test "dotfiles section refreshes on a {:dotfiles_changed} broadcast", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#dotfiles-tracked-count", "0")

      home = System.tmp_dir!()
      File.mkdir_p!(Path.join(home, ".config/fish"))
      {:ok, _} = TrackedPaths.add(%{path: Path.join(home, ".config/fish"), kind: "directory"})

      Phoenix.PubSub.broadcast(Fae.PubSub, Topics.dotfiles_status(), {:dotfiles_changed})

      assert has_element?(view, "#dotfiles-tracked-count", "1")
    end

    test "lists configured destinations", %{conn: conn} do
      destination = create_destination!(name: "Hetzner Falkenstein")

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Hetzner Falkenstein"
      assert html =~ destination.bucket
    end

    test "shows enabled job count and a row per job", %{conn: conn} do
      destination = create_destination!()
      job = create_job!(destination, name: "Daily Fae DB")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#jobs-enabled-count", "1")
      assert has_element?(view, "#job-row-#{job.id}", "Daily Fae DB")
    end

    test "system status section updates when SystemStatus broadcasts", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      Phoenix.PubSub.broadcast(
        Fae.PubSub,
        "system_status",
        {:system_status, %{boot_at: ~U[2026-05-16 12:00:00Z], uptime_seconds: 125}}
      )

      assert has_element?(view, "#uptime", "2m")
    end

    test "activity feed picks up a freshly-finished run via PubSub", %{conn: conn} do
      destination = create_destination!()
      job = create_job!(destination)
      {:ok, view, _html} = live(conn, ~p"/")

      {:ok, run} = Runs.start(job.id, DateTime.utc_now())

      {:ok, run} =
        Runs.finish(run, %{
          status: "failed",
          finished_at: DateTime.utc_now(),
          error_message: "boom"
        })

      Phoenix.PubSub.broadcast(
        Fae.PubSub,
        Topics.backups_runs(),
        {:run_finished, run.id, :failed, %{}}
      )

      assert has_element?(view, "#activity-#{run.id}", "failed")
      assert has_element?(view, "#activity-#{run.id}", "boom")
    end

    test "health pill flips to Degraded when a job's last run failed", %{conn: conn} do
      destination = create_destination!()
      job = create_job!(destination)

      {:ok, run} = Runs.start(job.id, DateTime.utc_now())

      {:ok, _run} =
        Runs.finish(run, %{
          status: "failed",
          finished_at: DateTime.utc_now(),
          error_message: "boom"
        })

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#health-banner", "Degraded")
      assert has_element?(view, "#jobs-failing-count", "1")
    end
  end

  defp create_destination!(overrides \\ []) do
    attrs =
      Map.merge(
        %{
          name: "Test Dest #{System.unique_integer([:positive])}",
          driver: "s3",
          endpoint_url: "https://example.com",
          region: "us",
          bucket: "test-bucket",
          access_key_id: "k",
          secret_access_key: "s"
        },
        Map.new(overrides)
      )

    {:ok, destination} = Destinations.create(attrs)
    destination
  end

  defp create_job!(destination, overrides \\ []) do
    attrs =
      Map.merge(
        %{
          name: "Daily Fae DB",
          slug: "daily-fae-db-#{System.unique_integer([:positive])}",
          source_kind: "file",
          source_path: "/tmp/fae.db",
          destination_id: destination.id,
          package_format: "as_is",
          recurrence_kind: "daily",
          time_of_day: "03:00",
          retention_strategy: "keep_last_n",
          retention_params: %{"n" => 7}
        },
        Map.new(overrides)
      )

    {:ok, job} = Jobs.create(attrs)
    job
  end
end
