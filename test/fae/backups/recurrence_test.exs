defmodule Fae.Backups.RecurrenceTest do
  use ExUnit.Case, async: true

  alias Fae.Backups.{Job, Recurrence}

  defp at!(iso, zone \\ "Etc/UTC") do
    {:ok, naive} = NaiveDateTime.from_iso8601(iso)
    DateTime.from_naive!(naive, zone)
  end

  defp next(job, now, zone \\ "Etc/UTC"),
    do: Recurrence.next_fire_in_zone(job, now, zone)

  describe "hourly" do
    test "fires at the next top-of-hour" do
      job = %Job{recurrence_kind: "hourly"}
      assert next(job, at!("2026-06-01T03:17:42")) == at!("2026-06-01T04:00:00")
    end

    test "exactly on the hour rolls to the next hour" do
      job = %Job{recurrence_kind: "hourly"}
      assert next(job, at!("2026-06-01T03:00:00")) == at!("2026-06-01T04:00:00")
    end
  end

  describe "daily" do
    test "fires today at time_of_day if still in the future" do
      job = %Job{recurrence_kind: "daily", time_of_day: "10:30"}
      assert next(job, at!("2026-06-01T08:00:00")) == at!("2026-06-01T10:30:00")
    end

    test "fires tomorrow if today's time has passed" do
      job = %Job{recurrence_kind: "daily", time_of_day: "10:30"}
      assert next(job, at!("2026-06-01T11:00:00")) == at!("2026-06-02T10:30:00")
    end

    test "exactly at time_of_day rolls to tomorrow" do
      job = %Job{recurrence_kind: "daily", time_of_day: "10:30"}
      assert next(job, at!("2026-06-01T10:30:00")) == at!("2026-06-02T10:30:00")
    end
  end

  describe "weekly" do
    # 2026-06-01 is a Monday (Date.day_of_week => 1)
    test "fires same week if target day-of-week is still ahead" do
      # Friday = 5
      job = %Job{recurrence_kind: "weekly", time_of_day: "09:00", day_of_week: 5}
      # Monday 08:00 → Friday 09:00 same week
      assert next(job, at!("2026-06-01T08:00:00")) == at!("2026-06-05T09:00:00")
    end

    test "wraps to next week if target day already passed" do
      # Sunday = 0
      job = %Job{recurrence_kind: "weekly", time_of_day: "09:00", day_of_week: 0}
      # Monday 08:00 → next Sunday is 2026-06-07
      assert next(job, at!("2026-06-01T08:00:00")) == at!("2026-06-07T09:00:00")
    end

    test "same day before time-of-day fires today" do
      # Monday = 1
      job = %Job{recurrence_kind: "weekly", time_of_day: "09:00", day_of_week: 1}
      assert next(job, at!("2026-06-01T08:00:00")) == at!("2026-06-01T09:00:00")
    end

    test "same day after time-of-day fires next week" do
      job = %Job{recurrence_kind: "weekly", time_of_day: "09:00", day_of_week: 1}
      assert next(job, at!("2026-06-01T10:00:00")) == at!("2026-06-08T09:00:00")
    end
  end

  describe "monthly" do
    test "fires this month if day still ahead" do
      job = %Job{recurrence_kind: "monthly", time_of_day: "03:00", day_of_month: 15}
      assert next(job, at!("2026-06-01T00:00:00")) == at!("2026-06-15T03:00:00")
    end

    test "wraps into next month past day-of-month" do
      job = %Job{recurrence_kind: "monthly", time_of_day: "03:00", day_of_month: 15}
      assert next(job, at!("2026-06-20T00:00:00")) == at!("2026-07-15T03:00:00")
    end

    test "wraps year boundary" do
      job = %Job{recurrence_kind: "monthly", time_of_day: "03:00", day_of_month: 15}
      assert next(job, at!("2026-12-20T00:00:00")) == at!("2027-01-15T03:00:00")
    end
  end

  describe "DST handling (Europe/Prague)" do
    # Prague spring-forward 2026: clocks jump from 02:00 → 03:00 on 2026-03-29.
    # Daily 02:30 schedule on 2026-03-29 hits a gap; we use the moment after.
    test "daily 02:30 on spring-forward day shifts into the gap-after window" do
      job = %Job{recurrence_kind: "daily", time_of_day: "02:30"}
      now_local = at!("2026-03-29T00:00:00", "Europe/Prague")
      utc_now = DateTime.shift_zone!(now_local, "Etc/UTC")

      result = Recurrence.next_fire_in_zone(job, utc_now, "Europe/Prague")
      local = DateTime.shift_zone!(result, "Europe/Prague")

      # 02:30 is in the gap (02:00→03:00); the resolver uses the
      # `after_gap` instant so the result is 03:00 local on the same day.
      assert local.day == 29
      assert local.hour == 3
      assert local.minute == 0
    end

    # Fall-back 2026: clocks jump 03:00 → 02:00 on 2026-10-25.
    # 02:30 happens twice; we pick the first occurrence.
    test "daily 02:30 on fall-back day picks the first occurrence" do
      job = %Job{recurrence_kind: "daily", time_of_day: "02:30"}
      now_local = at!("2026-10-25T00:00:00", "Europe/Prague")
      utc_now = DateTime.shift_zone!(now_local, "Etc/UTC")

      result = Recurrence.next_fire_in_zone(job, utc_now, "Europe/Prague")
      local = DateTime.shift_zone!(result, "Europe/Prague")

      assert local.day == 25
      assert local.hour == 2
      assert local.minute == 30
      # First occurrence is CEST (UTC+2), second is CET (UTC+1).
      assert local.std_offset == 3600
    end
  end
end
