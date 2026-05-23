defmodule FaeWeb.ArchiveLive.Index do
  @moduledoc """
  Lists archive runs with status and tally, plus a "New archive" action
  and a per-row retry for partial runs. Subscribes to `archive:runs` for
  real-time status updates.
  """
  use FaeWeb, :live_view

  alias Fae.Archive
  alias Fae.Archive.Runs
  alias FaeWeb.ArchiveLive.View

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :ok = Archive.subscribe_runs()

    {:ok,
     socket
     |> assign(:page_title, "Archive")
     |> load_runs()}
  end

  @impl true
  def handle_event("retry_failed", %{"id" => id}, socket) do
    _ = Archive.retry_failed(id)
    {:noreply, load_runs(socket)}
  end

  @impl true
  def handle_info({:run_changed, _id}, socket), do: {:noreply, load_runs(socket)}
  def handle_info({:run_finished, _id, _status}, socket), do: {:noreply, load_runs(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_runs(socket), do: assign(socket, :runs, Runs.list())

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <section class="card bg-base-200 p-6 space-y-4">
        <div class="flex items-center justify-between gap-4">
          <h2 class="text-xl font-semibold">Archive</h2>
          <.link navigate={~p"/archive/new"} class="btn btn-sm btn-primary">New archive</.link>
        </div>

        <%= if @runs == [] do %>
          <p class="opacity-75">
            No archives yet. <.link navigate={~p"/archive/new"} class="link">Start one</.link>
            to bulk-upload a folder to object storage.
          </p>
        <% else %>
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Label</th>
                  <th>Source</th>
                  <th>Destination</th>
                  <th>Status</th>
                  <th>Files</th>
                  <th>Size</th>
                  <th>Started</th>
                  <th class="text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={run <- @runs} id={"run-#{run.id}"}>
                  <td>
                    <.link navigate={~p"/archive/#{run.id}"} class="link">
                      {if run.label == "", do: "(no label)", else: run.label}
                    </.link>
                  </td>
                  <td class="font-mono text-xs opacity-75">{run.source_path}</td>
                  <td>{if run.destination, do: run.destination.name, else: "—"}</td>
                  <td>
                    <span class={["badge badge-sm", View.status_badge_class(run.status)]}>
                      {run.status}
                    </span>
                  </td>
                  <td class="text-sm">{run.uploaded_files}/{run.total_files}</td>
                  <td class="text-sm">{View.human_bytes(run.total_bytes)}</td>
                  <td class="text-sm">{format_dt(run.started_at)}</td>
                  <td class="whitespace-nowrap">
                    <div class="flex justify-end gap-1">
                      <button
                        :if={run.status == "partial"}
                        type="button"
                        phx-click="retry_failed"
                        phx-value-id={run.id}
                        class="btn btn-xs btn-warning btn-outline"
                      >
                        Retry failed
                      </button>
                      <.link navigate={~p"/archive/#{run.id}"} class="btn btn-xs btn-ghost">
                        View
                      </.link>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>
    </Layouts.app>
    """
  end

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
end
