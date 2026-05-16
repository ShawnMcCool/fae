defmodule FaeWeb.BackupsLive.JobShow do
  @moduledoc """
  Detail view for one backup job: configuration summary plus the
  history of recent runs. Subscribes to `backups:runs` so the table
  updates live as runs start/finish.
  """

  use FaeWeb, :live_view

  alias Fae.Backups
  alias Fae.Backups.{Jobs, Runs}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      :ok = Backups.subscribe_runs()
    end

    {:ok,
     socket
     |> assign(:job, Jobs.get!(id))
     |> assign(:runs, Runs.list_recent(id, 50))}
  end

  @impl true
  def handle_event("run_now", %{"id" => id}, socket) do
    _ = Backups.run_now(id)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_info({:run_started, _}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:run_finished, _, _, _}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp refresh(socket) do
    job = socket.assigns.job
    assign(socket, :runs, Runs.list_recent(job.id, 50))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <section class="card bg-base-200 p-6 space-y-4">
        <div class="flex items-center justify-between gap-4">
          <div>
            <h2 class="text-xl font-semibold">{@job.name}</h2>
            <div class="text-sm opacity-60 font-mono">{@job.slug}</div>
          </div>
          <div class="flex gap-2">
            <.link navigate={~p"/backups"} class="btn btn-sm btn-ghost">Back</.link>
            <.link navigate={~p"/backups/#{@job.id}/edit"} class="btn btn-sm btn-ghost">Edit</.link>
            <button
              type="button"
              phx-click="run_now"
              phx-value-id={@job.id}
              class="btn btn-sm btn-primary"
            >
              Run now
            </button>
          </div>
        </div>

        <dl class="grid grid-cols-[auto_1fr] gap-x-6 gap-y-1 text-sm">
          <dt class="opacity-60">Source</dt>
          <dd class="font-mono">{@job.source_kind} — {@job.source_path}</dd>
          <dt class="opacity-60">Destination</dt>
          <dd>{if @job.destination, do: @job.destination.name, else: "—"}</dd>
          <dt class="opacity-60">Object prefix</dt>
          <dd class="font-mono">{if @job.prefix in [nil, ""], do: "(none)", else: @job.prefix}</dd>
          <dt class="opacity-60">Package format</dt>
          <dd>{@job.package_format}</dd>
          <dt class="opacity-60">Retention</dt>
          <dd>{@job.retention_strategy} {inspect(@job.retention_params)}</dd>
          <dt class="opacity-60">Enabled</dt>
          <dd>{if @job.enabled, do: "yes", else: "no"}</dd>
        </dl>
      </section>

      <section class="card bg-base-200 p-6 space-y-2 mt-4">
        <h3 class="text-lg font-semibold">Recent runs</h3>

        <%= if @runs == [] do %>
          <p class="opacity-75 text-sm">No runs yet.</p>
        <% else %>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Status</th>
                  <th>Started</th>
                  <th>Duration</th>
                  <th>Size</th>
                  <th>SHA256</th>
                  <th>Object key</th>
                  <th>Error</th>
                </tr>
              </thead>
              <tbody>
                <%= for run <- @runs do %>
                  <tr>
                    <td>
                      <span class={["badge badge-sm", status_class(run.status)]}>{run.status}</span>
                    </td>
                    <td class="font-mono text-xs">{format_dt(run.started_at)}</td>
                    <td class="font-mono text-xs">
                      {format_duration(run.started_at, run.finished_at)}
                    </td>
                    <td class="font-mono text-xs">{format_size(run.byte_size)}</td>
                    <td class="font-mono text-xs truncate max-w-[10rem]">{short_sha(run.sha256)}</td>
                    <td class="font-mono text-xs truncate max-w-xs">{run.object_key || "—"}</td>
                    <td class="text-xs text-error truncate max-w-xs">{run.error_message}</td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>
    </Layouts.app>
    """
  end

  defp status_class("success"), do: "badge-success"
  defp status_class("running"), do: "badge-info"
  defp status_class("failed"), do: "badge-error"
  defp status_class("skipped"), do: "badge-warning"
  defp status_class(_), do: "badge-ghost"

  defp format_dt(nil), do: "—"

  defp format_dt(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

  defp format_duration(_, nil), do: "—"

  defp format_duration(%DateTime{} = start, %DateTime{} = finish) do
    seconds = DateTime.diff(finish, start, :second)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
    end
  end

  defp format_size(nil), do: "—"
  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KiB"

  defp format_size(bytes) when bytes < 1_073_741_824,
    do: "#{Float.round(bytes / 1_048_576, 1)} MiB"

  defp format_size(bytes), do: "#{Float.round(bytes / 1_073_741_824, 2)} GiB"

  defp short_sha(nil), do: "—"
  defp short_sha(sha), do: String.slice(sha, 0, 12)
end
