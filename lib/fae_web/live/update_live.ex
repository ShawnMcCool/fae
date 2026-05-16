defmodule FaeWeb.UpdateLive do
  @moduledoc """
  LiveView for in-app self-update. Renders the current version,
  classification of the latest known release, and offers Check Now /
  Update Now / Cancel actions. Subscribes to both
  `self_update:status` and `self_update:progress` so progress is
  reflected in real time without polling.
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
     |> assign(:current_version, Fae.Version.current_version())
     |> assign(:enabled?, SelfUpdate.enabled?())
     |> assign_cached_release()
     |> assign_apply_status()}
  end

  @impl true
  def handle_event("check_now", _params, socket) do
    case SelfUpdate.check_now() do
      {:ok, _job} -> {:noreply, assign(socket, :flash_message, "Check enqueued")}
      {:error, _} -> {:noreply, assign(socket, :flash_message, "Could not enqueue check")}
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

  @impl true
  def handle_info({:check_started}, socket) do
    {:noreply, assign(socket, :checking?, true)}
  end

  def handle_info({:check_complete, _outcome}, socket) do
    {:noreply,
     socket
     |> assign(:checking?, false)
     |> assign_cached_release()}
  end

  def handle_info({:progress, phase, percent}, socket) do
    {:noreply,
     socket
     |> assign(:apply_phase, phase)
     |> assign(:apply_percent, percent)}
  end

  def handle_info({:apply_failed, reason}, socket) do
    {:noreply,
     socket
     |> assign(:apply_phase, :failed)
     |> assign(:apply_error, reason)}
  end

  def handle_info({:apply_cancelled}, socket) do
    {:noreply,
     socket
     |> assign(:apply_phase, :idle)
     |> assign(:apply_error, nil)
     |> assign(:apply_percent, nil)}
  end

  def handle_info({:apply_succeeded}, socket) do
    {:noreply, assign(socket, :apply_phase, :done)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

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
    |> assign(:flash_message, nil)
  end

  @doc "Human-readable label for a classification. Public for testing."
  def classification_label(:update_available), do: "Update available"
  def classification_label(:up_to_date), do: "Up to date"
  def classification_label(:ahead_of_release), do: "Ahead of latest release"
  def classification_label(:unknown), do: "Unknown"

  @doc "Human-readable label for an apply phase. Public for testing."
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
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
          <%= if @latest_release do %>
            <div class="mt-2 text-sm opacity-75 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 items-baseline">
              <span>Latest tag</span>
              <span id="latest-tag" class="font-mono">{@latest_release.tag}</span>
              <span>Published</span>
              <span id="latest-published">
                {Calendar.strftime(@latest_release.published_at, "%Y-%m-%d %H:%M UTC")}
              </span>
            </div>
          <% end %>
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
              {inspect(@apply_error)}
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
      </section>
    </Layouts.app>
    """
  end
end
