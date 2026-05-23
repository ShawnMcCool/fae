defmodule FaeWeb.DashboardLive do
  @moduledoc """
  Operational status dashboard. Subscribes to every live operational
  topic Fae publishes (`system_status`, `backups:runs`, `backups:jobs`,
  `self_update:status`, `self_update:progress`) and re-renders on each
  event. View-shaping logic lives in `FaeWeb.DashboardView`.
  """

  use FaeWeb, :live_view

  alias Fae.Backups.{Jobs, Runs}
  alias Fae.Storage.Destinations
  alias Fae.{Clock, SelfUpdate, SystemStatus, Topics, Version}
  alias FaeWeb.DashboardView

  @recent_activity_limit 10

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = SystemStatus.subscribe()
      Phoenix.PubSub.subscribe(Fae.PubSub, Topics.backups_runs())
      Phoenix.PubSub.subscribe(Fae.PubSub, Topics.backups_jobs())
      Phoenix.PubSub.subscribe(Fae.PubSub, Topics.self_update_status())
      Phoenix.PubSub.subscribe(Fae.PubSub, Topics.self_update_progress())
    end

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> refresh()}
  end

  @impl true
  def handle_info({:system_status, state}, socket), do: {:noreply, refresh(socket, system: state)}
  def handle_info({:run_started, _run_id}, socket), do: {:noreply, refresh(socket)}

  def handle_info({:run_finished, _run_id, _outcome, _info}, socket),
    do: {:noreply, refresh(socket)}

  def handle_info({:job_changed, _job_id}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:check_started}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:check_complete, _outcome}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:progress, _phase, _percent}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:apply_failed, _reason}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:apply_cancelled}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:apply_succeeded}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-4">
        <.health_banner health={@view.health} />
        <.system_section system={@view.system} timezone={@timezone} />
        <.jobs_section jobs={@view.jobs} timezone={@timezone} />
        <.activity_section activity={@view.activity} timezone={@timezone} />
        <.destinations_section destinations={@view.destinations} />
      </div>
    </Layouts.app>
    """
  end

  attr :health, :map, required: true

  defp health_banner(assigns) do
    ~H"""
    <section
      id="health-banner"
      class={["card p-4 flex items-center gap-3", banner_class(@health.level)]}
    >
      <span class={["badge badge-lg", DashboardView.health_class(@health.level)]}>
        {DashboardView.health_label(@health.level)}
      </span>
      <p class="text-sm opacity-90">
        {@health.reason || "All systems nominal."}
      </p>
    </section>
    """
  end

  defp banner_class(:healthy), do: "bg-success/10"
  defp banner_class(:degraded), do: "bg-warning/10"
  defp banner_class(:down), do: "bg-error/10"

  attr :system, :map, required: true
  attr :timezone, :string, required: true

  defp system_section(assigns) do
    ~H"""
    <section id="system-section" class="card bg-base-200 p-6 space-y-3">
      <h2 class="text-xl font-semibold">System</h2>
      <dl class="grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 items-baseline">
        <dt class="text-sm opacity-75">Version</dt>
        <dd id="system-version" class="font-mono flex items-center gap-2">
          <span>{@system.version}</span>
          <.update_state_badge state={@system.update_state} version={@system.update_version} />
        </dd>
        <dt class="text-sm opacity-75">Booted at</dt>
        <dd id="boot-at" class="font-mono">
          <.local_datetime value={@system.boot_at} tz={@timezone} format={:datetime_seconds} />
        </dd>
        <dt class="text-sm opacity-75">Uptime</dt>
        <dd id="uptime" class="font-mono">{@system.uptime_label}</dd>
        <%= if @system.update_state == :applying do %>
          <dt class="text-sm opacity-75">Self-update phase</dt>
          <dd id="self-update-phase" class="font-mono">{@system.self_update_phase}</dd>
        <% end %>
        <%= if @system.self_update_error do %>
          <dt class="text-sm opacity-75">Last self-update error</dt>
          <dd id="self-update-error" class="text-error text-sm">
            {inspect(@system.self_update_error)}
          </dd>
        <% end %>
      </dl>
    </section>
    """
  end

  attr :state, :atom, required: true
  attr :version, :string, default: nil

  defp update_state_badge(%{state: :idle} = assigns), do: ~H""

  defp update_state_badge(%{state: :update_available} = assigns) do
    ~H"""
    <.link navigate={~p"/update"} class="badge badge-warning badge-sm">
      Update available → {@version}
    </.link>
    """
  end

  defp update_state_badge(%{state: :applying} = assigns) do
    ~H"""
    <span class="badge badge-info badge-sm">Updating…</span>
    """
  end

  defp update_state_badge(%{state: :failed} = assigns) do
    ~H"""
    <.link navigate={~p"/update"} class="badge badge-error badge-sm">Update failed</.link>
    """
  end

  attr :jobs, :map, required: true
  attr :timezone, :string, required: true

  defp jobs_section(assigns) do
    ~H"""
    <section id="jobs-section" class="card bg-base-200 p-6 space-y-4">
      <div class="flex items-baseline justify-between">
        <h2 class="text-xl font-semibold">Backup jobs</h2>
        <.link navigate={~p"/backups"} class="link text-sm">View all</.link>
      </div>

      <div class="stats stats-vertical sm:stats-horizontal bg-base-100 w-full">
        <div class="stat">
          <div class="stat-title">Enabled</div>
          <div id="jobs-enabled-count" class="stat-value text-3xl">{@jobs.enabled_count}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Failing (last run)</div>
          <div
            id="jobs-failing-count"
            class={["stat-value text-3xl", failing_color(@jobs.failing_count)]}
          >
            {@jobs.failing_count}
          </div>
        </div>
        <div class="stat">
          <div class="stat-title">Next fire</div>
          <div id="jobs-next-fire" class="stat-value text-base font-mono">
            <.local_datetime value={@jobs.soonest_next_fire} tz={@timezone} format={:datetime} />
          </div>
        </div>
      </div>

      <%= if @jobs.rows == [] do %>
        <p class="text-sm opacity-75">
          No jobs yet. <.link navigate={~p"/backups/new"} class="link">Create one</.link>.
        </p>
      <% else %>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Name</th>
                <th>Last run</th>
                <th>Schedule</th>
                <th>Next fire</th>
              </tr>
            </thead>
            <tbody>
              <%= for row <- @jobs.rows do %>
                <tr id={"job-row-#{row.job.id}"}>
                  <td>
                    <.link navigate={~p"/backups/#{row.job.id}"} class="link">{row.job.name}</.link>
                  </td>
                  <td>
                    <span class={["badge badge-sm", row.status_class]}>{row.status_label}</span>
                  </td>
                  <td class="text-sm">{row.schedule_summary}</td>
                  <td class="text-sm font-mono">
                    <.local_datetime value={row.next_fire} tz={@timezone} format={:datetime} />
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </section>
    """
  end

  defp failing_color(0), do: "text-success"
  defp failing_color(_), do: "text-error"

  attr :activity, :list, required: true
  attr :timezone, :string, required: true

  defp activity_section(assigns) do
    ~H"""
    <section id="activity-section" class="card bg-base-200 p-6 space-y-3">
      <h2 class="text-xl font-semibold">Recent activity</h2>

      <%= if @activity == [] do %>
        <p class="text-sm opacity-75">No runs yet.</p>
      <% else %>
        <ul class="divide-y divide-base-300">
          <%= for row <- @activity do %>
            <li id={"activity-#{row.run.id}"} class="py-2 flex items-baseline gap-3 text-sm">
              <span class={["badge badge-sm", row.status_class]}>{row.run.status}</span>
              <span class="font-medium">{row.job_name}</span>
              <.local_datetime value={row.started_at} tz={@timezone} format={:datetime} />
              <span class="opacity-75">·</span>
              <span class="font-mono">{row.duration_label}</span>
              <%= if row.error_preview do %>
                <span
                  class="text-error truncate max-w-md"
                  title={row.run.error_message}
                >
                  {row.error_preview}
                </span>
              <% end %>
            </li>
          <% end %>
        </ul>
      <% end %>
    </section>
    """
  end

  attr :destinations, :list, required: true

  defp destinations_section(assigns) do
    ~H"""
    <section id="destinations-section" class="card bg-base-200 p-6 space-y-3">
      <div class="flex items-baseline justify-between">
        <h2 class="text-xl font-semibold">Destinations</h2>
        <.link navigate={~p"/backups/destinations"} class="link text-sm">View all</.link>
      </div>

      <%= if @destinations == [] do %>
        <p class="text-sm opacity-75">
          No destinations configured. <.link navigate={~p"/backups/destinations/new"} class="link">Add one</.link>.
        </p>
      <% else %>
        <ul class="divide-y divide-base-300">
          <%= for destination <- @destinations do %>
            <li id={"destination-#{destination.id}"} class="py-2 flex items-baseline gap-3 text-sm">
              <span class="font-medium">{destination.name}</span>
              <span class="badge badge-ghost badge-sm">{destination.driver}</span>
              <span class="font-mono opacity-75">{destination.bucket}</span>
              <span class="font-mono opacity-60 truncate max-w-md">{destination.endpoint_url}</span>
            </li>
          <% end %>
        </ul>
      <% end %>
    </section>
    """
  end

  defp refresh(socket, overrides \\ []) do
    now = Clock.now()
    jobs = Jobs.list()
    last_runs = Map.new(jobs, fn job -> {job.id, Runs.last(job.id)} end)
    recent_runs = Runs.list_recent_all(@recent_activity_limit)
    destinations = Destinations.list()
    self_update = SelfUpdate.current_status()
    latest_release = release_from_cache()
    system = Keyword.get(overrides, :system) || SystemStatus.get_state()

    view =
      DashboardView.build(%{
        jobs: jobs,
        last_runs: last_runs,
        recent_runs: recent_runs,
        destinations: destinations,
        version: Version.current_version(),
        latest_release: latest_release,
        self_update_phase: self_update.phase,
        self_update_error: self_update.error,
        system: system,
        now: now
      })

    assign(socket, :view, view)
  end

  defp release_from_cache do
    case SelfUpdate.cached_release() do
      {:ok, release} -> release
      :none -> nil
    end
  end
end
