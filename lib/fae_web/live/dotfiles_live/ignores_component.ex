defmodule FaeWeb.DotfilesLive.IgnoresComponent do
  @moduledoc """
  Edit the ignore patterns for one tracked path. Shows a textarea
  pre-filled with the path's `ignore_patterns`; **save** persists them via
  `TrackedPaths.set_ignores/2` and tells the parent to close with
  `{:ignores_done}`. **Cancel** also sends `{:ignores_done}`.

  Assigns: `id`, `tracked_path` (`%Fae.Dotfiles.TrackedPath{}`).
  """
  use FaeWeb, :live_component

  alias Fae.Dotfiles.TrackedPaths

  @impl true
  def handle_event("save", %{"patterns" => patterns}, socket) do
    {:ok, _} = TrackedPaths.set_ignores(socket.assigns.tracked_path, patterns)
    send(self(), {:ignores_done})
    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket) do
    send(self(), {:ignores_done})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-lg">
        <div class="flex items-center mb-1">
          <h3 class="text-lg font-semibold">Ignore patterns</h3>
          <div class="flex-1"></div>
          <button
            type="button"
            phx-click="cancel"
            phx-target={@myself}
            class="btn btn-ghost btn-sm btn-square"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
        <p class="text-xs opacity-60 font-mono mb-3 break-all">{@tracked_path.path}</p>

        <form phx-submit="save" phx-target={@myself}>
          <p class="text-sm opacity-70 mb-2">
            One gitignore-style pattern per line. These are excluded from this path's backup.
          </p>
          <textarea
            name="patterns"
            rows="8"
            class="textarea textarea-bordered w-full font-mono text-sm"
            placeholder="node_modules&#10;*.log"
          >{@tracked_path.ignore_patterns}</textarea>

          <div class="flex justify-end gap-2 mt-4">
            <button type="button" phx-click="cancel" phx-target={@myself} class="btn btn-ghost">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">Save</button>
          </div>
        </form>
      </div>
      <label class="modal-backdrop" phx-click="cancel" phx-target={@myself}>Close</label>
    </div>
    """
  end
end
