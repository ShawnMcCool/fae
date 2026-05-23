defmodule FaeWeb.UpdateLiveTest do
  # async: false — subscribes to shared self_update topics.
  use FaeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fae.SelfUpdate.UpdateChecker
  alias Fae.Topics
  alias FaeWeb.TimeDisplay
  alias FaeWeb.UpdateLive

  setup do
    UpdateChecker.clear_cache()
    on_exit(fn -> UpdateChecker.clear_cache() end)
    :ok
  end

  describe "pure render helpers" do
    test "classification_label/1" do
      assert UpdateLive.classification_label(:update_available) == "Update available"
      assert UpdateLive.classification_label(:up_to_date) == "Up to date"
      assert UpdateLive.classification_label(:ahead_of_release) == "Ahead of latest release"
      assert UpdateLive.classification_label(:unknown) == "Unknown"
    end

    test "phase_label/1" do
      assert UpdateLive.phase_label(:idle) == "Idle"
      assert UpdateLive.phase_label(:downloading) == "Downloading"
      assert UpdateLive.phase_label(:handing_off) == "Restarting service"
      assert UpdateLive.phase_label(:done) == "Done"
    end

    test "show_update_button? only when an update is available and updater is idle/done/failed" do
      assert UpdateLive.show_update_button?(%{
               classification: :update_available,
               apply_phase: :idle
             })

      assert UpdateLive.show_update_button?(%{
               classification: :update_available,
               apply_phase: :done
             })

      refute UpdateLive.show_update_button?(%{classification: :up_to_date, apply_phase: :idle})

      refute UpdateLive.show_update_button?(%{
               classification: :update_available,
               apply_phase: :downloading
             })
    end

    test "show_cancel_button? only during cancellable phases" do
      for phase <- [:preparing, :downloading, :extracting] do
        assert UpdateLive.show_cancel_button?(%{apply_phase: phase}),
               "expected cancel button visible during #{phase}"
      end

      for phase <- [:idle, :handing_off, :done, :failed] do
        refute UpdateLive.show_cancel_button?(%{apply_phase: phase}),
               "expected cancel button hidden during #{phase}"
      end
    end

    test "time_ago/2 buckets sub-minute, minutes, hours, days" do
      now = ~U[2026-05-16 12:00:00Z]

      assert TimeDisplay.time_ago(nil, now) == nil
      assert TimeDisplay.time_ago(DateTime.add(now, -2, :second), now) == "just now"
      assert TimeDisplay.time_ago(DateTime.add(now, -30, :second), now) == "30s ago"
      assert TimeDisplay.time_ago(DateTime.add(now, -120, :second), now) == "2m ago"
      assert TimeDisplay.time_ago(DateTime.add(now, -7200, :second), now) == "2h ago"
      assert TimeDisplay.time_ago(DateTime.add(now, -172_800, :second), now) == "2d ago"
    end

    test "error_label maps known structured errors to human strings" do
      assert UpdateLive.error_label(:no_update_pending) =~ "No update"
      assert UpdateLive.error_label(:invalid_tag) =~ "malformed"
      assert UpdateLive.error_label(:already_running) =~ "already in progress"
      assert UpdateLive.error_label(:not_found) =~ "404"
      assert UpdateLive.error_label({:http_error, 500}) =~ "HTTP 500"

      assert UpdateLive.error_label({:rate_limited, ~U[2026-05-16 13:00:00Z]}) =~ "rate limit"

      assert UpdateLive.error_label({:download, :checksum_mismatch}) =~ "Download failed"
      assert UpdateLive.error_label({:download, :checksum_mismatch}) =~ "SHA256"

      assert UpdateLive.error_label({:stage, :symlink}) =~ "symlink"

      assert UpdateLive.error_label({:stage, {:missing_required, ["bin/fae-install"]}}) =~
               "bin/fae-install"

      assert UpdateLive.error_label({:task_crashed, :killed}) =~ "crashed"
    end

    test "error_label falls back gracefully for unknown shapes" do
      assert UpdateLive.error_label(:something_unexpected) =~ "Unexpected"
    end

    test "service_state_label/1" do
      assert UpdateLive.service_state_label(%{under_systemd: false}) == "Not under systemd"

      assert UpdateLive.service_state_label(%{under_systemd: true, active: true, enabled: true}) ==
               "Active, enabled at boot"

      assert UpdateLive.service_state_label(%{under_systemd: true, active: true, enabled: false}) ==
               "Active, not enabled at boot"

      assert UpdateLive.service_state_label(%{under_systemd: true, active: false, enabled: false}) ==
               "Inactive"
    end

    test "show_service_controls? requires under_systemd AND systemd_available" do
      assert UpdateLive.show_service_controls?(%{under_systemd: true, systemd_available: true})
      refute UpdateLive.show_service_controls?(%{under_systemd: false, systemd_available: true})
      refute UpdateLive.show_service_controls?(%{under_systemd: true, systemd_available: false})
    end
  end

  describe "GET /update" do
    test "renders the current version + idle phase by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/update")

      assert has_element?(view, "#current-version")
      assert has_element?(view, "#apply-phase-label", "Idle")
      assert has_element?(view, "#classification-label", "Unknown")
    end

    test "shows latest tag when a release is cached", %{conn: conn} do
      release = %{
        version: "0.1.0",
        tag: "v0.1.0",
        published_at: ~U[2026-05-16 12:00:00Z],
        html_url: "https://github.com/ShawnMcCool/fae/releases/tag/v0.1.0",
        body: "Initial"
      }

      UpdateChecker.cache_result({:ok, release})

      {:ok, view, _html} = live(conn, ~p"/update")
      assert has_element?(view, "#latest-tag", "v0.1.0")
    end

    test "shows the not-enabled notice in test env", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/update")
      assert has_element?(view, "#not-enabled-notice")
    end

    test "reflects an incoming :progress broadcast in real time", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/update")

      Phoenix.PubSub.broadcast(
        Fae.PubSub,
        Topics.self_update_progress(),
        {:progress, :downloading, 42}
      )

      assert has_element?(view, "#apply-phase-label", "Downloading")
      assert has_element?(view, "#apply-progress")
    end
  end
end
