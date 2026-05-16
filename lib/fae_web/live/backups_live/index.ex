defmodule FaeWeb.BackupsLive.Index do
  @moduledoc """
  Lists every backup job with last-run status, next scheduled run,
  and per-row actions (Run now, Edit, Delete). Subscribes to
  `backups:jobs` and `backups:runs` for real-time updates.
  """

  use FaeWeb, :live_view

  alias Fae.Backups
  alias Fae.Backups.{Jobs, Recurrence, Runs}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Backups.subscribe_jobs()
      :ok = Backups.subscribe_runs()
    end

    {:ok,
     socket
     |> assign(:page_title, "Backup jobs")
     |> load_rows()}
  end

  @impl true
  def handle_event("run_now", %{"id" => id}, socket) do
    _ = Backups.run_now(id)
    {:noreply, load_rows(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Jobs.get(id) do
      nil ->
        {:noreply, socket}

      job ->
        {:ok, _} = Jobs.delete(job)
        {:noreply, load_rows(socket)}
    end
  end

  @impl true
  def handle_info({:job_changed, _}, socket), do: {:noreply, load_rows(socket)}
  def handle_info({:run_started, _}, socket), do: {:noreply, load_rows(socket)}
  def handle_info({:run_finished, _, _, _}, socket), do: {:noreply, load_rows(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp load_rows(socket) do
    rows =
      Jobs.list()
      |> Enum.map(fn job ->
        %{
          job: job,
          last_run: Runs.last(job.id),
          next_fire: safe_next_fire(job)
        }
      end)

    assign(socket, rows: rows)
  end

  defp safe_next_fire(job) do
    Recurrence.next_fire(job, DateTime.utc_now())
  rescue
    _ -> nil
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <section class="card bg-base-200 p-6 space-y-4">
        <div class="flex items-center justify-between gap-4">
          <h2 class="text-xl font-semibold">Backup jobs</h2>
          <div class="flex gap-2">
            <.link navigate={~p"/backups/destinations"} class="btn btn-sm btn-ghost">
              Destinations
            </.link>
            <.link navigate={~p"/backups/new"} class="btn btn-sm btn-primary">
              New job
            </.link>
          </div>
        </div>

        <%= if @rows == [] do %>
          <p class="opacity-75">
            No backup jobs yet. <.link navigate={~p"/backups/new"} class="link">Create one</.link>.
          </p>
        <% else %>
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Source</th>
                  <th>Destination</th>
                  <th>Schedule</th>
                  <th>Last run</th>
                  <th>Next run</th>
                  <th class="text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= for %{job: job, last_run: last_run, next_fire: next_fire} <- @rows do %>
                  <tr id={"job-#{job.id}"}>
                    <td>
                      <.link navigate={~p"/backups/#{job.id}"} class="link">{job.name}</.link>
                      <div class="text-xs opacity-60 font-mono">{job.slug}</div>
                    </td>
                    <td class="font-mono text-xs">
                      <span class="badge badge-ghost badge-sm">{job.source_kind}</span>
                      <span class="opacity-75">{job.source_path}</span>
                    </td>
                    <td>
                      {if job.destination, do: job.destination.name, else: "—"}
                    </td>
                    <td class="text-sm">{schedule_summary(job)}</td>
                    <td>
                      {last_run_cell(assigns, last_run)}
                    </td>
                    <td class="text-sm">{format_dt(next_fire, job.enabled)}</td>
                    <td class="text-right space-x-1">
                      <button
                        type="button"
                        phx-click="run_now"
                        phx-value-id={job.id}
                        class="btn btn-xs btn-primary"
                      >
                        Run now
                      </button>
                      <.link navigate={~p"/backups/#{job.id}/edit"} class="btn btn-xs btn-ghost">
                        Edit
                      </.link>
                      <button
                        type="button"
                        phx-click="delete"
                        phx-value-id={job.id}
                        data-confirm={"Delete '#{job.name}'?"}
                        class="btn btn-xs btn-error btn-outline"
                      >
                        Delete
                      </button>
                    </td>
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

  defp last_run_cell(assigns, nil) do
    ~H"""
    <span class="opacity-50">—</span>
    """
  end

  defp last_run_cell(assigns, last_run) do
    assigns = assign(assigns, :run, last_run)

    ~H"""
    <div class="flex flex-col gap-0.5">
      <span class={["badge badge-sm", status_class(@run.status)]}>{@run.status}</span>
      <span class="text-xs opacity-75 font-mono">{format_dt(@run.started_at, true)}</span>
      <%= if @run.error_message do %>
        <span class="text-xs text-error truncate max-w-xs" title={@run.error_message}>
          {@run.error_message}
        </span>
      <% end %>
    </div>
    """
  end

  defp status_class("success"), do: "badge-success"
  defp status_class("running"), do: "badge-info"
  defp status_class("failed"), do: "badge-error"
  defp status_class("skipped"), do: "badge-warning"
  defp status_class(_), do: "badge-ghost"

  defp schedule_summary(%{enabled: false}), do: "(disabled)"
  defp schedule_summary(%{recurrence_kind: "hourly"}), do: "Hourly"
  defp schedule_summary(%{recurrence_kind: "daily", time_of_day: t}), do: "Daily at #{t}"

  defp schedule_summary(%{recurrence_kind: "weekly", time_of_day: t, day_of_week: dow}) do
    "Weekly #{day_name(dow)} at #{t}"
  end

  defp schedule_summary(%{recurrence_kind: "monthly", time_of_day: t, day_of_month: dom}) do
    "Monthly day #{dom} at #{t}"
  end

  defp schedule_summary(_), do: "—"

  defp day_name(0), do: "Sun"
  defp day_name(1), do: "Mon"
  defp day_name(2), do: "Tue"
  defp day_name(3), do: "Wed"
  defp day_name(4), do: "Thu"
  defp day_name(5), do: "Fri"
  defp day_name(6), do: "Sat"
  defp day_name(_), do: "?"

  defp format_dt(_dt, false), do: "(disabled)"
  defp format_dt(nil, _), do: "—"

  defp format_dt(%DateTime{} = dt, _) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end
end
