defmodule FaeWeb.TimeDisplayTest do
  use ExUnit.Case, async: true

  alias FaeWeb.TimeDisplay

  describe "format/3 at UTC (output-preserving baseline)" do
    @utc ~U[2026-05-23 14:30:45Z]

    test ":datetime matches the legacy '%Y-%m-%d %H:%M UTC' string" do
      assert TimeDisplay.format(@utc, "UTC", :datetime) == "2026-05-23 14:30 UTC"
    end

    test ":datetime_seconds includes seconds" do
      assert TimeDisplay.format(@utc, "UTC", :datetime_seconds) == "2026-05-23 14:30:45 UTC"
    end

    test ":date is zone-free" do
      assert TimeDisplay.format(@utc, "UTC", :date) == "2026-05-23"
    end

    test ":time is HH:MM plus abbreviation" do
      assert TimeDisplay.format(@utc, "UTC", :time) == "14:30 UTC"
    end

    test "nil renders an em dash" do
      assert TimeDisplay.format(nil, "UTC", :datetime) == "—"
    end
  end

  describe "format/3 shifts into the target zone (incl. DST)" do
    test "summer date renders as CEST (UTC+2)" do
      assert TimeDisplay.format(~U[2026-07-01 12:00:00Z], "Europe/Amsterdam", :datetime) ==
               "2026-07-01 14:00 CEST"
    end

    test "winter date renders as CET (UTC+1)" do
      assert TimeDisplay.format(~U[2026-01-01 12:00:00Z], "Europe/Amsterdam", :datetime) ==
               "2026-01-01 13:00 CET"
    end

    test "an unknown zone falls back to a UTC render" do
      assert TimeDisplay.format(~U[2026-05-23 14:30:00Z], "Mars/Phobos", :datetime) ==
               "2026-05-23 14:30 UTC"
    end
  end

  describe "time_ago/2" do
    test "buckets sub-minute, minutes, hours, days; nil passes through" do
      now = ~U[2026-05-23 12:00:00Z]
      assert TimeDisplay.time_ago(nil, now) == nil
      assert TimeDisplay.time_ago(DateTime.add(now, -2, :second), now) == "just now"
      assert TimeDisplay.time_ago(DateTime.add(now, -30, :second), now) == "30s ago"
      assert TimeDisplay.time_ago(DateTime.add(now, -120, :second), now) == "2m ago"
      assert TimeDisplay.time_ago(DateTime.add(now, -7200, :second), now) == "2h ago"
      assert TimeDisplay.time_ago(DateTime.add(now, -172_800, :second), now) == "2d ago"
    end
  end
end
