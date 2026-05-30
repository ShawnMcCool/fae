defmodule FaeWeb.DotfilesLive.Index do
  @moduledoc """
  The Dotfiles board: a compact health strip (on/off toggle, cadence
  dropdown, "Back up now") over the curated set of tracked `$HOME`
  config paths, grouped by parent directory. Subscribes to
  `dotfiles:status` and `dotfiles:runs` for real-time updates; all data
  shaping lives in `FaeWeb.DotfilesView` (decision 019).
  """

  use FaeWeb, :live_view

  alias Fae.Dotfiles
  alias Fae.Dotfiles.{Git, TrackedPath, TrackedPaths}
  alias FaeWeb.DotfilesView

  @cadence_options [
    {"Hourly", 3600},
    {"Every 30 min", 1800},
    {"Every 6 hours", 21_600},
    {"Daily", 86_400}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Dotfiles.subscribe_status()
      :ok = Dotfiles.subscribe_runs()
    end

    {:ok,
     socket
     |> assign(:page_title, "Dotfiles")
     |> load()}
  end

  @impl true
  def handle_info({:dotfiles_changed}, socket), do: {:noreply, load(socket)}
  def handle_info({:run_started, _}, socket), do: {:noreply, load(socket)}
  def handle_info({:run_finished, _, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_enabled", _params, socket) do
    current = socket.assigns.view.health.enabled
    {:ok, _} = Dotfiles.update_config(%{enabled: !current})
    {:noreply, load(socket)}
  end

  def handle_event("set_cadence", %{"seconds" => seconds}, socket) do
    {:ok, _} = Dotfiles.update_config(%{interval_seconds: String.to_integer(seconds)})
    {:noreply, load(socket)}
  end

  def handle_event("backup_now", _params, socket) do
    Dotfiles.run_now()
    {:noreply, load(socket)}
  end

  def handle_event("stop_tracking", %{"path" => path}, socket) do
    case Enum.find(Dotfiles.list_tracked(), &(&1.path == path)) do
      %TrackedPath{} = tracked -> TrackedPaths.remove(tracked)
      nil -> :noop
    end

    {:noreply, load(socket)}
  end

  def handle_event("restore_path", %{"path" => path}, socket) do
    # Best-effort restore of a missing path from the repo.
    _ = Git.checkout([path])
    {:noreply, load(socket)}
  end

  def handle_event("track_path", _params, socket) do
    # Placeholder: the Track-a-path modal is wired in Task 14.
    {:noreply, socket}
  end

  defp load(socket) do
    view =
      DotfilesView.build(%{
        config: Dotfiles.get_config(),
        tracked: Dotfiles.list_tracked(),
        runs: Dotfiles.recent_runs(20),
        now: Fae.Clock.now()
      })

    assign(socket, :view, view)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :cadence_options, @cadence_options)

    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <section class="space-y-6">
        <div class="flex items-start gap-4">
          <div>
            <h2 class="text-xl font-semibold">Dotfiles</h2>
            <p class="text-sm opacity-60">Auto-backup of curated <code>$HOME</code> config paths.</p>
          </div>
          <div class="flex-1"></div>
          <button type="button" phx-click="backup_now" class="btn btn-sm btn-ghost">
            Back up now
          </button>
          <button type="button" phx-click="track_path" class="btn btn-sm btn-primary">
            <.icon name="hero-plus" class="size-4" /> Track a path
          </button>
        </div>

        <div class="flex flex-wrap items-center gap-3 card bg-base-200 px-4 py-3 text-sm">
          <span class={[
            "inline-block size-2.5 rounded-full",
            if(@view.health.enabled, do: "bg-success", else: "bg-base-content/30")
          ]}>
          </span>

          <span :if={@view.health.enabled}>
            <b>On</b> · backs up {cadence_label(@view.health.interval_seconds)}
          </span>
          <span :if={not @view.health.enabled} class="opacity-70">
            <b>Off</b> · auto-backup paused
          </span>

          <div class="dropdown dropdown-bottom">
            <div tabindex="0" role="button" class="link link-primary text-xs">
              Cadence: {cadence_label(@view.health.interval_seconds)}
            </div>
            <ul
              tabindex="0"
              class="dropdown-content menu bg-base-100 rounded-box z-10 w-48 p-2 shadow"
            >
              <li :for={{label, seconds} <- @cadence_options}>
                <button
                  type="button"
                  phx-click="set_cadence"
                  phx-value-seconds={seconds}
                  class={if @view.health.interval_seconds == seconds, do: "active"}
                >
                  {label}
                </button>
              </li>
            </ul>
          </div>

          <span class="opacity-60">{last_backup_summary(@view.health)}</span>

          <div class="flex-1"></div>

          <button
            type="button"
            phx-click="toggle_enabled"
            class={["toggle", if(@view.health.enabled, do: "toggle-success")]}
            role="switch"
            aria-checked={to_string(@view.health.enabled)}
            aria-label="Toggle auto-backup"
          >
          </button>
        </div>

        <div>
          <div class="flex items-center gap-2 mb-3">
            <h3 class="text-sm font-semibold">Tracked paths</h3>
            <span class="text-xs opacity-50">{tracked_count(@view.groups)}</span>
          </div>

          <p :if={@view.groups == []} class="text-sm opacity-60">
            No paths tracked yet. Use <b>Track a path</b> to add one.
          </p>

          <div :for={group <- @view.groups} class="mb-4">
            <div class="text-xs opacity-50 font-mono mb-1">{group.header}</div>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-6">
              <div
                :for={item <- group.items}
                class="group flex items-center gap-2 px-2 py-1 rounded hover:bg-base-200 text-sm"
              >
                <span
                  :if={item.status in [:pending, :missing]}
                  class={[
                    "inline-block size-2 rounded-full flex-none",
                    status_dot_class(item.status)
                  ]}
                  title={to_string(item.status)}
                >
                </span>
                <.icon
                  :if={item.status == :ok}
                  name={item_icon(item.kind)}
                  class="size-3.5 opacity-50 flex-none"
                />

                <span class={[
                  "flex-1 min-w-0 truncate",
                  item.kind == "directory" && "font-medium",
                  status_text_class(item.status)
                ]}>
                  {item.name}
                </span>

                <span :if={item.ignored_count > 0} class="text-xs opacity-40">
                  {item.ignored_count} ignored
                </span>
                <span :if={item.status == :pending} class="text-xs opacity-40">pending</span>
                <span :if={item.status == :missing} class="text-xs text-error">missing</span>

                <button
                  :if={item.status == :missing}
                  type="button"
                  phx-click="restore_path"
                  phx-value-path={item.path}
                  class="btn btn-ghost btn-xs opacity-0 group-hover:opacity-100"
                  title="Restore from repo"
                >
                  Restore
                </button>
                <button
                  type="button"
                  phx-click="stop_tracking"
                  phx-value-path={item.path}
                  class="btn btn-ghost btn-xs btn-square opacity-0 group-hover:opacity-100"
                  title="Stop tracking"
                  aria-label={"Stop tracking #{item.name}"}
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>
            </div>
          </div>
        </div>

        <%!-- Recent backups list intentionally omitted for now (history wired in a later pass). --%>
      </section>
    </Layouts.app>
    """
  end

  @doc "Human label for a cadence in seconds, falling back to a minute count."
  def cadence_label(3600), do: "every hour"
  def cadence_label(1800), do: "every 30 min"
  def cadence_label(21_600), do: "every 6 hours"
  def cadence_label(86_400), do: "daily"
  def cadence_label(seconds), do: "every #{div(seconds, 60)} min"

  @doc "Count of tracked items across all groups, as a string."
  def tracked_count(groups) do
    groups |> Enum.map(&length(&1.items)) |> Enum.sum() |> to_string()
  end

  @doc "Short summary line for the last backup and push state."
  def last_backup_summary(%{last_backup_at: nil}), do: "· no backups yet"

  def last_backup_summary(%{last_push_ok: false, last_push_error: error}) when is_binary(error) do
    "· last push failed: #{error}"
  end

  def last_backup_summary(%{last_push_ok: false}), do: "· last push failed"
  def last_backup_summary(_), do: "· pushed ✓"

  defp status_dot_class(:pending), do: "bg-info"
  defp status_dot_class(:missing), do: "bg-error"

  defp status_text_class(:pending), do: "text-info"
  defp status_text_class(:missing), do: "text-error"
  defp status_text_class(_), do: ""

  defp item_icon("directory"), do: "hero-folder"
  defp item_icon(_), do: "hero-document"
end
