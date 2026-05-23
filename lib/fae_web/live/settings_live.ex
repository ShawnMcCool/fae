defmodule FaeWeb.SettingsLive do
  @moduledoc """
  Settings page. Currently lets the user choose the timezone that all
  dates/times render in across Fae. The choice is persisted via
  `Fae.Display` and broadcast on the `"settings"` topic, so every open
  page re-renders immediately (see `FaeWeb.DisplayScope`).

  A colocated JS hook reports the browser's IANA timezone so the user
  can adopt it in one click; a searchable `<select>` is the manual
  override. `@timezone` (the current value) is supplied by DisplayScope.
  """
  use FaeWeb, :live_view

  alias Fae.Display

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:detected_timezone, nil)
     |> assign(:zone_options, Display.zone_options())}
  end

  @impl true
  def handle_event("timezone_detected", %{"timezone" => tz}, socket) do
    detected = if Display.valid_timezone?(tz), do: tz, else: nil
    {:noreply, assign(socket, :detected_timezone, detected)}
  end

  def handle_event("use_detected", _params, socket) do
    case socket.assigns.detected_timezone do
      nil -> {:noreply, socket}
      tz -> save(socket, tz)
    end
  end

  def handle_event("save", %{"timezone" => tz}, socket) do
    save(socket, tz)
  end

  defp save(socket, tz) do
    case Display.put_timezone(tz) do
      {:ok, _tz} -> {:noreply, put_flash(socket, :info, "Timezone updated.")}
      {:error, :invalid_timezone} -> {:noreply, put_flash(socket, :error, "Unknown timezone.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <section id="settings" class="space-y-6 max-w-xl">
        <header class="space-y-1">
          <h1 class="text-2xl font-semibold">Settings</h1>
          <p class="text-sm opacity-75">Preferences for this Fae instance.</p>
        </header>

        <div id="timezone-card" class="card bg-base-200 p-4 space-y-3">
          <h2 class="text-lg font-medium">Timezone</h2>
          <p class="text-sm opacity-75">
            All dates and times across Fae are shown in this timezone. Current:
            <span id="current-timezone" class="font-mono">{@timezone}</span>
          </p>

          <div id="tz-detector" phx-hook=".TimezoneDetect"></div>

          <div :if={@detected_timezone} id="detected-row" class="flex items-center gap-3">
            <span class="text-sm">
              Detected: <span class="font-mono">{@detected_timezone}</span>
            </span>
            <button type="button" class="btn btn-soft btn-success btn-sm" phx-click="use_detected">
              Use this
            </button>
          </div>

          <form phx-submit="save" class="flex items-end gap-2">
            <div class="flex-1">
              <.input
                type="select"
                id="timezone-select"
                name="timezone"
                label="Pick manually"
                value={@timezone}
                options={@zone_options}
              />
            </div>
            <button type="submit" class="btn btn-primary">Save</button>
          </form>
        </div>
      </section>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".TimezoneDetect">
        export default {
          mounted() {
            const tz = Intl.DateTimeFormat().resolvedOptions().timeZone
            if (tz) this.pushEvent("timezone_detected", {timezone: tz})
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
