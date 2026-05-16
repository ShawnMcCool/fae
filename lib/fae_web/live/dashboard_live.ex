defmodule FaeWeb.DashboardLive do
  @moduledoc """
  Placeholder dashboard for the walking skeleton. Demonstrates the
  desktop-app pattern end-to-end: subscribe to a supervised process via
  PubSub, render its current state, update in real time as it broadcasts.

  Subsequent tools will follow this same shape (subscribe → render → handle_info).
  """

  use FaeWeb, :live_view

  alias Fae.SystemStatus

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = SystemStatus.subscribe()
    end

    {:ok, assign(socket, status: SystemStatus.get_state())}
  end

  @impl true
  def handle_info({:system_status, status}, socket) do
    {:noreply, assign(socket, status: status)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="system-status" class="card bg-base-200 p-6">
        <h2 class="text-xl font-semibold mb-4">System status</h2>
        <dl class="grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 items-baseline">
          <dt class="text-sm opacity-75">Booted at</dt>
          <dd id="boot-at" class="font-mono">
            {Calendar.strftime(@status.boot_at, "%Y-%m-%d %H:%M:%S UTC")}
          </dd>
          <dt class="text-sm opacity-75">Uptime (seconds)</dt>
          <dd id="uptime-seconds" class="font-mono">{@status.uptime_seconds}</dd>
        </dl>
      </section>
    </Layouts.app>
    """
  end
end
