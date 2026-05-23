defmodule FaeWeb.ArchiveLive.Index do
  @moduledoc """
  Lists archives with status and tally, plus a "New archive" action and
  per-row Sync now / Delete. Subscribes to `archive:runs` for real-time
  status updates.
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
  def handle_event("sync", %{"id" => id}, socket) do
    _ = Archive.sync(id)
    {:noreply, load_runs(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Runs.get(id) do
      nil ->
        {:noreply, socket}

      run ->
        {:ok, _} = Runs.delete(run)
        {:noreply, load_runs(socket)}
    end
  end

  @impl true
  def handle_info({:run_changed, _id}, socket), do: {:noreply, load_runs(socket)}
  def handle_info({:run_finished, _id, _status}, socket), do: {:noreply, load_runs(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_runs(socket), do: assign(socket, :runs, Runs.list())

  @doc false
  def display_name(%{name: name}) when is_binary(name) and name != "", do: name
  def display_name(%{label: label}) when is_binary(label) and label != "", do: label
  def display_name(_run), do: "(unnamed)"

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
            to mirror a folder up to object storage.
          </p>
        <% else %>
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Source</th>
                  <th>Destination</th>
                  <th>Remote folder</th>
                  <th>Status</th>
                  <th>Files</th>
                  <th>Started</th>
                  <th class="text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={run <- @runs} id={"run-#{run.id}"}>
                  <td>
                    <.link navigate={~p"/archive/#{run.id}"} class="link">{display_name(run)}</.link>
                  </td>
                  <td class="font-mono text-xs opacity-75">{run.source_path}</td>
                  <td>{if run.destination, do: run.destination.name, else: "—"}</td>
                  <td class="font-mono text-xs opacity-75">
                    {if run.label == "", do: "(prefix root)", else: run.label}
                  </td>
                  <td>
                    <span class={["badge badge-sm", View.status_badge_class(run.status)]}>
                      {run.status}
                    </span>
                  </td>
                  <td class="text-sm">{run.uploaded_files}/{run.total_files}</td>
                  <td class="text-sm">
                    <.local_datetime value={run.started_at} tz={@timezone} format={:datetime} />
                  </td>
                  <td class="whitespace-nowrap">
                    <div class="flex justify-end gap-1">
                      <button
                        type="button"
                        phx-click="sync"
                        phx-value-id={run.id}
                        class="btn btn-xs btn-primary"
                      >
                        Sync now
                      </button>
                      <.link navigate={~p"/archive/#{run.id}"} class="btn btn-xs btn-ghost">
                        View
                      </.link>
                      <button
                        type="button"
                        phx-click="delete"
                        phx-value-id={run.id}
                        data-confirm={"Delete '#{display_name(run)}'? (Objects already in the bucket are not removed.)"}
                        class="btn btn-xs btn-error btn-outline"
                      >
                        Delete
                      </button>
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
end
