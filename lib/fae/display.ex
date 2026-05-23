defmodule Fae.Display do
  @moduledoc """
  User display preferences. Currently just the timezone that all
  dates/times render in across the web UI.

  Backed by `Fae.Settings` under the `"display"` key; reads default to
  `"UTC"` until the user picks a zone. Writes validate against the IANA
  zone list and broadcast on the `"settings"` PubSub topic, so open
  LiveViews re-render in the new zone immediately (see
  `FaeWeb.DisplayScope`).
  """

  alias Fae.Settings

  @settings_key "display"
  @default_timezone "UTC"

  @doc "The configured timezone, or \"UTC\" if none is set."
  @spec timezone() :: String.t()
  def timezone do
    case Settings.get_by_key(@settings_key) do
      {:ok, %{value: %{"timezone" => tz}}} when is_binary(tz) -> tz
      _ -> default_timezone()
    end
  end

  @doc "Validate and persist a timezone. Broadcasts the change."
  @spec put_timezone(String.t()) :: {:ok, String.t()} | {:error, :invalid_timezone}
  def put_timezone(timezone) when is_binary(timezone) do
    if valid_timezone?(timezone) do
      {:ok, _entry} = Settings.put(@settings_key, %{"timezone" => timezone})
      {:ok, timezone}
    else
      {:error, :invalid_timezone}
    end
  end

  @doc "True when `timezone` is a known IANA zone name."
  @spec valid_timezone?(term()) :: boolean()
  def valid_timezone?(timezone) when is_binary(timezone), do: timezone in zone_list()
  def valid_timezone?(_), do: false

  @doc "Sorted list of IANA zone names for a `<select>`."
  @spec zone_options() :: [String.t()]
  def zone_options, do: Enum.sort(zone_list())

  @doc "The default timezone used before the user picks one."
  @spec default_timezone() :: String.t()
  def default_timezone, do: @default_timezone

  defp zone_list, do: Tzdata.zone_list()
end
