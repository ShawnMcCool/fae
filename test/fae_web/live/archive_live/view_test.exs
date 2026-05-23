defmodule FaeWeb.ArchiveLive.ViewTest do
  use ExUnit.Case, async: true

  alias FaeWeb.ArchiveLive.View

  describe "percent/2" do
    test "is 100 when there is nothing to move" do
      assert View.percent(0, 0) == 100
    end

    test "floors the percentage" do
      assert View.percent(1, 3) == 33
    end

    test "caps at 100" do
      assert View.percent(10, 5) == 100
    end

    test "is 0 at the start" do
      assert View.percent(0, 100) == 0
    end
  end

  describe "human_bytes/1" do
    test "bytes" do
      assert View.human_bytes(512) == "512 B"
    end

    test "kibibytes with one decimal" do
      assert View.human_bytes(1536) == "1.5 KiB"
    end

    test "mebibytes" do
      assert View.human_bytes(5 * 1024 * 1024) == "5.0 MiB"
    end

    test "gibibytes" do
      assert View.human_bytes(3 * 1024 * 1024 * 1024) == "3.0 GiB"
    end

    test "zero" do
      assert View.human_bytes(0) == "0 B"
    end
  end

  describe "throughput_bytes_per_sec/2" do
    test "nil when no time has elapsed" do
      assert View.throughput_bytes_per_sec(100, 0) == nil
    end

    test "computes bytes per second" do
      assert View.throughput_bytes_per_sec(1000, 1000) == 1000.0
    end
  end

  describe "status_badge_class/1" do
    test "maps known statuses" do
      assert View.status_badge_class("completed") == "badge-success"
      assert View.status_badge_class("failed") == "badge-error"
      assert View.status_badge_class("partial") == "badge-warning"
      assert View.status_badge_class("uploading") == "badge-info"
    end

    test "unknown status falls back to ghost" do
      assert View.status_badge_class("???") == "badge-ghost"
    end
  end
end
