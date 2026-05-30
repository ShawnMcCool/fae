defmodule FaeWeb.UpdateLive do
  @moduledoc """
  LiveView for in-app self-update. Renders the current version,
  classification of the latest known release, and offers Check Now /
  Update Now / Cancel actions. Surfaces the systemd unit's state and
  exposes Restart / Stop. Subscribes to both `self_update:status` and
  `self_update:progress` so progress is reflected in real time.
  """

  use FaeWeb, :live_view

  alias Fae.SelfUpdate

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = SelfUpdate.subscribe()
      :ok = SelfUpdate.subscribe_progress()
    end

    {:ok,
     socket
     |> assign(:page_title, "Updates")
     |> assign(:current_version, Fae.Version.current_version())
     |> assign(:enabled?, SelfUpdate.enabled?())
     |> assign(:service_state, SelfUpdate.service_state())
     |> assign(:last_check_at, last_check_at())
     |> assign_cached_release()
     |> assign_apply_status()}
  end

  @impl true
  def handle_event("check_now", _params, socket) do
    case SelfUpdate.check_now() do
      {:ok, _job} -> {:noreply, assign(socket, :checking?, true)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("update_now", _params, socket) do
    case SelfUpdate.apply_pending() do
      :ok ->
        {:noreply, socket |> assign(:apply_phase, :preparing) |> assign(:apply_error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :apply_error, reason)}
    end
  end

  def handle_event("cancel", _params, socket) do
    _ = SelfUpdate.cancel_apply()
    {:noreply, socket}
  end

  def handle_event("restart_service", _params, socket) do
    _ = SelfUpdate.service_restart()
    {:noreply, socket}
  end

  def handle_event("stop_service", _params, socket) do
    _ = SelfUpdate.service_stop()
    {:noreply, socket}
  end

  @impl true
  def handle_info({:check_started}, socket) do
    {:noreply, assign(socket, :checking?, true)}
  end

  def handle_info({:check_complete, _outcome}, socket) do
    {:noreply,
     socket
     |> assign(:checking?, false)
     |> assign(:last_check_at, last_check_at())
     |> assign_cached_release()}
  end

  def handle_info({:progress, phase, percent}, socket) do
    {:noreply,
     socket
     |> assign(:apply_phase, phase)
     |> assign(:apply_percent, percent)
     |> signal_restart_expected(phase)}
  end

  def handle_info({:apply_failed, reason}, socket) do
    {:noreply,
     socket
     |> assign(:apply_phase, :failed)
     |> assign(:apply_error, reason)
     |> push_event("fae-update-aborted", %{})}
  end

  def handle_info({:apply_cancelled}, socket) do
    {:noreply,
     socket
     |> assign(:apply_phase, :idle)
     |> assign(:apply_error, nil)
     |> assign(:apply_percent, nil)
     |> push_event("fae-update-aborted", %{})}
  end

  def handle_info({:apply_succeeded}, socket) do
    {:noreply, assign(socket, :apply_phase, :done)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # Applying an update ends in a service restart that drops the LiveView
  # socket. Tell the client a restart is expected so the disconnect shows the
  # friendly "applying update" notice instead of the generic "Something went
  # wrong!" error toast. The client clears the flag on reconnect; we also clear
  # it on failure/cancellation (handlers above), since no restart follows.
  @restart_expected_phases [:preparing, :downloading, :extracting, :handing_off]

  defp signal_restart_expected(socket, phase) when phase in @restart_expected_phases do
    push_event(socket, "fae-updating", %{})
  end

  defp signal_restart_expected(socket, _phase), do: socket

  defp assign_cached_release(socket) do
    case SelfUpdate.cached_release() do
      {:ok, release} ->
        classification =
          case Fae.SelfUpdate.UpdateChecker.compare(release, socket.assigns.current_version) do
            classification when is_atom(classification) -> classification
            _ -> :unknown
          end

        socket
        |> assign(:latest_release, release)
        |> assign(:classification, classification)

      :none ->
        socket
        |> assign(:latest_release, nil)
        |> assign(:classification, :unknown)
    end
  end

  defp assign_apply_status(socket) do
    %{phase: phase, error: error} = Fae.SelfUpdate.current_status()

    socket
    |> assign(:apply_phase, phase)
    |> assign(:apply_error, error)
    |> assign(:apply_percent, nil)
    |> assign(:checking?, false)
  end

  defp last_check_at do
    case Fae.SelfUpdate.Storage.get_last_check_at() do
      {:ok, at} -> at
      :none -> nil
    end
  end

  # --- Pure helpers (tested directly in UpdateLiveTest) ---

  @doc "Human-readable label for a classification."
  def classification_label(:update_available), do: "Update available"
  def classification_label(:up_to_date), do: "Up to date"
  def classification_label(:ahead_of_release), do: "Ahead of latest release"
  def classification_label(:unknown), do: "Unknown"

  @doc "Human-readable label for an apply phase."
  def phase_label(:idle), do: "Idle"
  def phase_label(:preparing), do: "Preparing"
  def phase_label(:downloading), do: "Downloading"
  def phase_label(:extracting), do: "Verifying and extracting"
  def phase_label(:handing_off), do: "Restarting service"
  def phase_label(:done), do: "Done"
  def phase_label(:failed), do: "Failed"

  @doc "Should the 'Update now' button be visible?"
  def show_update_button?(%{classification: :update_available, apply_phase: phase})
      when phase in [:idle, :failed, :done],
      do: true

  def show_update_button?(_), do: false

  @doc "Should the 'Cancel' button be visible?"
  def show_cancel_button?(%{apply_phase: phase})
      when phase in [:preparing, :downloading, :extracting],
      do: true

  def show_cancel_button?(_), do: false

  @doc """
  Human-readable label for an error reason from the check or apply pipeline.
  Pure: takes a structured error tuple/atom, returns a string.
  """
  def error_label(:no_update_pending), do: "No update is available right now."
  def error_label(:invalid_tag), do: "The latest release tag is malformed."
  def error_label(:already_running), do: "An update is already in progress."
  def error_label(:not_running), do: "No update is in progress."

  def error_label(:past_point_of_no_return),
    do: "The installer has already started; cancellation is no longer possible."

  def error_label(:not_found), do: "GitHub returned 404 — no releases yet?"
  def error_label(:malformed), do: "GitHub API returned an unexpected response shape."

  def error_label({:rate_limited, reset_at}),
    do: "GitHub API rate limit hit. Resets at #{format_at(reset_at)}."

  def error_label({:http_error, status}), do: "GitHub API returned HTTP #{status}."

  def error_label({:transport_error, _reason}),
    do: "Network error reaching GitHub. Check your connection."

  def error_label({:download, reason}), do: "Download failed: #{error_label(reason)}"
  def error_label({:stage, reason}), do: "Staging failed: #{stage_error_label(reason)}"
  def error_label({:handoff, reason}), do: "Handoff to installer failed: #{inspect(reason)}"
  def error_label({:task_crashed, _reason}), do: "Apply task crashed unexpectedly."

  def error_label(:checksum_mismatch),
    do: "Downloaded tarball did not match its published SHA256."

  def error_label(:checksum_missing),
    do: "Couldn't find this tarball's checksum entry in SHA256SUMS."

  def error_label(:too_large), do: "Download exceeded the 200MB size cap."
  def error_label(other), do: "Unexpected error: #{inspect(other)}"

  defp stage_error_label(:absolute_path), do: "tarball contains an absolute path"
  defp stage_error_label(:path_traversal), do: "tarball contains a parent-dir traversal"
  defp stage_error_label(:symlink), do: "tarball contains a symlink"
  defp stage_error_label(:non_regular_file), do: "tarball contains a non-regular file"
  defp stage_error_label(:oversized), do: "tarball is too large"

  defp stage_error_label({:missing_required, paths}),
    do: "missing required files: #{Enum.join(paths, ", ")}"

  defp stage_error_label({:tar_error, _reason}), do: "tar extraction failed"
  defp stage_error_label(other), do: "stage error: #{inspect(other)}"

  defp format_at(nil), do: "an unknown time"
  # Rendered in UTC on purpose: this is the rate-limit reset time embedded
  # in a pure error string, which has no socket/@timezone in scope.
  defp format_at(%DateTime{} = dt), do: FaeWeb.TimeDisplay.format(dt, "UTC", :time)

  @doc "Human-readable label for a systemd service state map (from Service.state/0)."
  def service_state_label(%{under_systemd: false}), do: "Not under systemd"
  def service_state_label(%{active: true, enabled: true}), do: "Active, enabled at boot"
  def service_state_label(%{active: true, enabled: false}), do: "Active, not enabled at boot"
  def service_state_label(%{active: false}), do: "Inactive"

  @doc "Should the Restart / Stop buttons be visible?"
  def show_service_controls?(%{under_systemd: true, systemd_available: true}), do: true
  def show_service_controls?(_), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <section id="update" class="space-y-6">
        <header class="space-y-1">
          <h1 class="text-2xl font-semibold">Updates</h1>
          <p class="text-sm opacity-75">
            Running version <span id="current-version" class="font-mono">{@current_version}</span>
          </p>
          <%= unless @enabled? do %>
            <div id="not-enabled-notice" class="alert alert-soft alert-info text-sm">
              Self-update is only enabled in production builds. In dev/test, this page reflects
              cached state but no checks fire and no apply will run.
            </div>
          <% end %>
        </header>

        <div id="classification" class="card bg-base-200 p-4">
          <div class="flex flex-row items-baseline justify-between">
            <span class="text-sm opacity-75">Status</span>
            <span id="classification-label" class="font-medium">
              {classification_label(@classification)}
            </span>
          </div>
          <div class="mt-2 text-sm opacity-75 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 items-baseline">
            <%= if @latest_release do %>
              <span>Latest tag</span>
              <span id="latest-tag" class="font-mono">
                <a href={@latest_release.html_url} target="_blank" rel="noopener" class="link">
                  {@latest_release.tag}
                </a>
              </span>
              <span>Published</span>
              <span id="latest-published">
                <.local_datetime
                  value={@latest_release.published_at}
                  tz={@timezone}
                  format={:datetime}
                />
              </span>
            <% end %>
            <%= if @last_check_at do %>
              <span>Last checked</span>
              <.relative_time id="last-checked" value={@last_check_at} tz={@timezone} />
            <% end %>
          </div>
        </div>

        <div id="apply-status" class="card bg-base-200 p-4">
          <div class="flex flex-row items-baseline justify-between">
            <span class="text-sm opacity-75">Apply phase</span>
            <span id="apply-phase-label" class="font-medium">{phase_label(@apply_phase)}</span>
          </div>
          <%= if is_integer(@apply_percent) do %>
            <progress
              id="apply-progress"
              class="progress w-full mt-2"
              value={@apply_percent}
              max="100"
            />
          <% end %>
          <%= if @apply_error do %>
            <div id="apply-error" class="alert alert-soft alert-error text-sm mt-2">
              {error_label(@apply_error)}
            </div>
          <% end %>
        </div>

        <div id="actions" class="flex flex-row gap-2 flex-wrap">
          <button
            id="check-now"
            class="btn btn-soft btn-primary"
            phx-click="check_now"
            disabled={@checking?}
          >
            {if @checking?, do: "Checking…", else: "Check now"}
          </button>
          <%= if show_update_button?(assigns) do %>
            <button id="update-now" class="btn btn-soft btn-success" phx-click="update_now">
              Update now
            </button>
          <% end %>
          <%= if show_cancel_button?(assigns) do %>
            <button id="cancel" class="btn btn-ghost" phx-click="cancel">
              Cancel
            </button>
          <% end %>
        </div>

        <%= if @latest_release && @latest_release.body != "" do %>
          <details id="release-notes" class="card bg-base-200 p-4">
            <summary class="font-medium">Release notes</summary>
            <pre
              class="text-sm whitespace-pre-wrap mt-2"
              phx-no-curly-interpolation
            ><%= @latest_release.body %></pre>
          </details>
        <% end %>

        <div id="service" class="card bg-base-200 p-4 space-y-3">
          <div class="flex flex-row items-baseline justify-between">
            <h2 class="text-lg font-medium">Service</h2>
            <span id="service-state-label" class="text-sm">
              {service_state_label(@service_state)}
            </span>
          </div>
          <%= if @service_state.unit_name do %>
            <div class="text-sm opacity-75 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 items-baseline">
              <span>Unit</span>
              <span id="service-unit" class="font-mono">{@service_state.unit_name}</span>
            </div>
          <% end %>
          <%= if show_service_controls?(@service_state) do %>
            <div class="flex flex-row gap-2 flex-wrap">
              <button
                id="restart-service"
                class="btn btn-soft btn-warning"
                phx-click="restart_service"
              >
                Restart service
              </button>
              <button
                id="stop-service"
                class="btn btn-ghost"
                phx-click="stop_service"
                data-confirm="Really stop the service? You'll need to run `systemctl --user start fae` from a terminal to bring it back."
              >
                Stop service
              </button>
            </div>
          <% end %>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
