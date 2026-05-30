defmodule FaeWeb.DotfilesLive.ImportComponent do
  @moduledoc """
  Guided import from the legacy dot-filer layout.

  Walks the user through a four-step flow: **preview** (classify each target
  path) → **confirm** (acknowledge the destructive de-reference) → **run** (the
  migration) → **done** (results + the manual systemd-timer cleanup command).

  The migration de-references symlinks and removes files, so the destructive
  nature is surfaced explicitly and the old dot-filer systemd timer is **not**
  disabled silently — the exact `systemctl --user disable --now` command is shown
  for the user to run.

  Display/formatting logic lives in pure functions so it can be unit-tested
  without rendering.
  """

  use FaeWeb, :live_component

  alias Fae.Dotfiles.Migration

  # The dot-filer timer is the legacy unit that must be disabled after import.
  # We default to the conventional name and show the command rather than running
  # it; the user confirms the unit on their own machine.
  @dot_filer_timer_unit "dot-filer.timer"

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:step, fn -> :preview end)
      |> assign_new(:preview, fn -> Migration.preview() end)
      |> assign_new(:report, fn -> nil end)
      |> assign_new(:error, fn -> nil end)

    {:ok, socket}
  end

  @impl true
  def handle_event("to_confirm", _params, socket) do
    {:noreply, assign(socket, :step, :confirm)}
  end

  @impl true
  def handle_event("back_to_preview", _params, socket) do
    {:noreply, assign(socket, :step, :preview)}
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    send(self(), {:import_cancel})
    {:noreply, socket}
  end

  @impl true
  def handle_event("close", _params, socket) do
    send(self(), {:import_done})
    {:noreply, socket}
  end

  @impl true
  def handle_event("run", _params, socket) do
    case Migration.run() do
      {:ok, report} ->
        {:noreply, assign(socket, step: :done, report: report, error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, step: :preview, error: reason)}
    end
  end

  @doc "The systemd timer unit for the legacy dot-filer tool."
  def dot_filer_timer_unit, do: @dot_filer_timer_unit

  @doc "The exact command the user should run to disable the legacy timer."
  def disable_timer_command(unit \\ @dot_filer_timer_unit) do
    "systemctl --user disable --now #{unit}"
  end

  @doc """
  Summarize a preview list into counts by state, for display.
  """
  def summarize_preview(preview) do
    %{
      symlinked: Enum.count(preview, &(&1.state == :symlinked_into_old_repo)),
      real: Enum.count(preview, &(&1.state == :real)),
      missing: Enum.count(preview, &(&1.state == :missing))
    }
  end

  @doc "Human-readable label for a preview state."
  def state_label(:symlinked_into_old_repo), do: "symlink (dot-filer)"
  def state_label(:real), do: "real file"
  def state_label(:missing), do: "missing"

  @doc "Human-readable label for a migration error reason."
  def error_message(:already_initialized),
    do: "Dotfiles are already initialized — nothing to import."

  def error_message(reason), do: "Migration failed: #{inspect(reason)}"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :summary, summarize_preview(assigns.preview))

    ~H"""
    <div class="space-y-4">
      <.header>
        Import from dot-filer
        <:subtitle>Migrate your existing dot-filer targets to bare-repo-in-place.</:subtitle>
      </.header>

      <div :if={@error} class="text-error">{error_message(@error)}</div>

      <div :if={@step == :preview} class="space-y-4">
        <p>
          {@summary.symlinked} symlinked, {@summary.real} already real, {@summary.missing} missing.
        </p>
        <ul class="space-y-1">
          <li :for={entry <- @preview} class="flex items-center gap-3">
            <span class="font-mono text-sm">{entry.path}</span>
            <span class="text-xs opacity-70">{state_label(entry.state)}</span>
          </li>
        </ul>
        <div class="flex gap-3">
          <.button phx-click="to_confirm" phx-target={@myself}>Continue</.button>
          <.button phx-click="cancel" phx-target={@myself} class="btn-ghost">Cancel</.button>
        </div>
      </div>

      <div :if={@step == :confirm} class="space-y-4">
        <p class="text-warning">
          This will de-reference your dot-filer symlinks in place: the symlinks are
          replaced with real files at their original locations. A timestamped safety
          copy is taken first, and the old dot-filer mirror tree is left intact.
        </p>
        <div class="flex gap-3">
          <.button phx-click="run" phx-target={@myself}>Run import</.button>
          <.button phx-click="back_to_preview" phx-target={@myself} class="btn-ghost">
            Back
          </.button>
        </div>
      </div>

      <div :if={@step == :done} class="space-y-4">
        <p>
          Imported {@report.imported} path(s). Safety copy:
          <span class="font-mono text-sm">{@report.safety_copy}</span>
        </p>
        <div class="space-y-2">
          <p>Now disable the old dot-filer timer by running this command yourself:</p>
          <pre class="bg-base-200 p-3 rounded font-mono text-sm">{disable_timer_command()}</pre>
        </div>
        <.button phx-click="close" phx-target={@myself}>Done</.button>
      </div>
    </div>
    """
  end
end
