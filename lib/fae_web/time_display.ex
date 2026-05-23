defmodule FaeWeb.TimeDisplay do
  @moduledoc """
  The single, enforced chokepoint for rendering dates and times in the
  web UI.

  Every user-facing date/time MUST go through `local_datetime/1`,
  `relative_time/1`, or `format/3`. A custom Credo check
  (`Fae.Credo.Check.UnlocalizedDateTime`) fails the build if any other
  module under `lib/fae_web` calls `Calendar.strftime` or
  `DateTime.to_iso8601` directly.

  All persisted timestamps are UTC; these helpers shift them into the
  user's configured timezone (`Fae.Display`) for display.
  """
  use Phoenix.Component

  @type format :: :date | :datetime | :datetime_seconds | :time

  @doc """
  Format a UTC `DateTime` in `timezone` (an IANA name). Returns "—" for
  nil. Falls back to a UTC render if the zone is unknown.
  """
  @spec format(DateTime.t() | nil, String.t(), format()) :: String.t()
  def format(nil, _timezone, _fmt), do: "—"

  def format(%DateTime{} = utc, timezone, fmt) do
    case DateTime.shift_zone(utc, timezone) do
      {:ok, local} -> render(local, fmt)
      {:error, _reason} -> render(utc, fmt)
    end
  end

  defp render(dt, :date), do: Calendar.strftime(dt, "%Y-%m-%d")
  defp render(dt, :datetime), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M") <> " " <> dt.zone_abbr

  defp render(dt, :datetime_seconds),
    do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S") <> " " <> dt.zone_abbr

  defp render(dt, :time), do: Calendar.strftime(dt, "%H:%M") <> " " <> dt.zone_abbr

  @doc """
  Relative-time label like "2m ago" or "just now" for a past timestamp.
  Returns nil for nil input. Timezone-independent.
  """
  @spec time_ago(DateTime.t() | nil, DateTime.t()) :: String.t() | nil
  def time_ago(at, now \\ DateTime.utc_now())
  def time_ago(nil, _now), do: nil

  def time_ago(%DateTime{} = at, %DateTime{} = now) do
    seconds = DateTime.diff(now, at, :second)

    cond do
      seconds < 5 -> "just now"
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  attr :value, :any, required: true, doc: "a UTC DateTime, or nil"
  attr :tz, :string, required: true, doc: "IANA timezone name (from @timezone)"

  attr :format, :atom,
    default: :datetime,
    values: [:date, :datetime, :datetime_seconds, :time]

  attr :rest, :global

  @doc "Render a UTC datetime in the user's timezone with a fuller tooltip."
  def local_datetime(assigns) do
    ~H"""
    <time datetime={iso(@value)} title={title(@value, @tz)} {@rest}>
      {format(@value, @tz, @format)}
    </time>
    """
  end

  attr :value, :any, required: true, doc: "a UTC DateTime, or nil"
  attr :tz, :string, required: true, doc: "IANA timezone name (from @timezone)"
  attr :rest, :global

  @doc ~S(Render a relative "2m ago" label with the absolute local time as a tooltip.)
  def relative_time(assigns) do
    ~H"""
    <time datetime={iso(@value)} title={title(@value, @tz)} {@rest}>{time_ago(@value)}</time>
    """
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp title(nil, _tz), do: nil
  defp title(%DateTime{} = dt, tz), do: format(dt, tz, :datetime_seconds)
end
