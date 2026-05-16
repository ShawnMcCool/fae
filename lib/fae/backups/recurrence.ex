defmodule Fae.Backups.Recurrence do
  @moduledoc """
  Pure recurrence resolution: given a job + `now`, returns the next
  `DateTime` (in UTC) the job should fire.

  Schedules are interpreted in the locally-configured time zone
  (`config :fae, :timezone`, defaulting to `Etc/UTC`). Day/month
  arithmetic uses `Date.add/2` so DST transitions are handled
  correctly: a daily 03:00 schedule fires at local 03:00 on both
  sides of a spring-forward / fall-back boundary.

  Day-of-month is capped at 28 in the job changeset, so monthly
  arithmetic never needs to special-case month-end (Feb 30 etc.).
  """

  alias Fae.Backups.Job

  @spec next_fire(Job.t(), DateTime.t()) :: DateTime.t()
  def next_fire(%Job{} = job, %DateTime{} = now) do
    zone = Application.get_env(:fae, :timezone, "Etc/UTC")
    next_fire_in_zone(job, now, zone)
  end

  @doc """
  Same as `next_fire/2` but with the time zone passed explicitly.
  Lets async tests avoid mutating application env.
  """
  @spec next_fire_in_zone(Job.t(), DateTime.t(), String.t()) :: DateTime.t()
  def next_fire_in_zone(%Job{} = job, %DateTime{} = now, zone) do
    local_now = DateTime.shift_zone!(now, zone)

    local_next =
      case job.recurrence_kind do
        "hourly" -> next_hourly(local_now)
        "daily" -> next_daily(local_now, job.time_of_day)
        "weekly" -> next_weekly(local_now, job.time_of_day, job.day_of_week)
        "monthly" -> next_monthly(local_now, job.time_of_day, job.day_of_month)
      end

    DateTime.shift_zone!(local_next, "Etc/UTC")
  end

  defp next_hourly(local_now) do
    base = %{local_now | minute: 0, second: 0, microsecond: {0, 0}}

    if DateTime.compare(base, local_now) == :gt do
      base
    else
      add_seconds(base, 3600)
    end
  end

  defp next_daily(local_now, tod) do
    candidate = at_time(local_now, tod)

    if DateTime.compare(candidate, local_now) == :gt do
      candidate
    else
      add_days(candidate, 1)
    end
  end

  defp next_weekly(local_now, tod, dow_target) do
    today_at = at_time(local_now, tod)
    days_ahead = rem(dow_target - dow_index(today_at) + 7, 7)
    candidate = add_days(today_at, days_ahead)

    if DateTime.compare(candidate, local_now) == :gt do
      candidate
    else
      add_days(candidate, 7)
    end
  end

  defp next_monthly(local_now, tod, day) do
    candidate = day_of_month(local_now, day, tod)

    if DateTime.compare(candidate, local_now) == :gt do
      candidate
    else
      day_of_month(add_months(local_now, 1), day, tod)
    end
  end

  defp at_time(local_now, tod) do
    {h, m} = parse_tod(tod)
    date = DateTime.to_date(local_now)
    to_datetime_at(date, Time.new!(h, m, 0), local_now.time_zone)
  end

  defp day_of_month(local_now, day, tod) do
    {h, m} = parse_tod(tod)
    date = %Date{year: local_now.year, month: local_now.month, day: day}
    to_datetime_at(date, Time.new!(h, m, 0), local_now.time_zone)
  end

  defp to_datetime_at(date, time, zone) do
    naive = NaiveDateTime.new!(date, time)

    case DateTime.from_naive(naive, zone) do
      {:ok, dt} -> dt
      # Spring-forward: the local time doesn't exist; use the moment
      # after the gap.
      {:gap, _before, after_gap} -> after_gap
      # Fall-back: the local time happens twice; use the first.
      {:ambiguous, first, _second} -> first
    end
  end

  # Adds N calendar days, re-resolving the local time on the new
  # date. Using Date.add (rather than +86_400 seconds) keeps the
  # local clock time stable across DST transitions.
  defp add_days(dt, n) do
    date = Date.add(DateTime.to_date(dt), n)
    time = DateTime.to_time(dt)
    to_datetime_at(date, time, dt.time_zone)
  end

  defp add_months(dt, 1) do
    {year, month} = if dt.month == 12, do: {dt.year + 1, 1}, else: {dt.year, dt.month + 1}
    %{dt | year: year, month: month}
  end

  defp add_seconds(dt, seconds), do: DateTime.add(dt, seconds, :second)

  # Date.day_of_week returns Mon=1..Sun=7. Job.day_of_week stores
  # Sun=0..Sat=6.
  defp dow_index(dt) do
    case Date.day_of_week(dt) do
      7 -> 0
      n -> n
    end
  end

  defp parse_tod(<<h::binary-size(2), ":", m::binary-size(2)>>) do
    {String.to_integer(h), String.to_integer(m)}
  end
end
