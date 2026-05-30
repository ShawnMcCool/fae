defmodule FaeWeb.DotfilesLive.TrackPathComponent do
  @moduledoc """
  The "Track a path" modal: three ways to pick `$HOME` config paths for
  backup, all writing into one `selected` set.

    * ✨ **Suggestions** — entries under `suggest_base` (default `~/.config`)
      not already tracked, shown as clickable pills.
    * **Browser** — a checkbox file tree rooted at `browse_root` (default
      `$HOME`); folders are both selectable and navigable, files are
      selectable; already-tracked entries are disabled with a "tracked" tag.
    * **Manual field** — type a path; it is validated against disk before it
      joins `selected`.

  On **submit** each selected path is tracked via `TrackedPaths.add/1`
  (kind inferred from `File.dir?/1`) and the parent is told to close with
  `{:track_done}`; **cancel** sends `{:track_cancel}`.

  Assigns: `id`, `tz`, `tracked_paths` (list of absolute path strings),
  `browse_root`, `suggest_base`.
  """
  use FaeWeb, :live_component

  alias Fae.Dotfiles.{Paths, Suggestions, TrackedPaths}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if socket.assigns[:initialized?] do
      {:ok, socket}
    else
      socket =
        socket
        |> assign_new(:browse_root, fn -> Paths.work_tree() end)
        |> assign_new(:suggest_base, fn -> Suggestions.default_base() end)
        |> assign(:selected, MapSet.new())
        |> assign(:manual_error, nil)
        |> assign(:initialized?, true)

      {:ok, assign_cwd(socket, socket.assigns.browse_root)}
    end
  end

  @impl true
  def handle_event("toggle_select", %{"path" => path}, socket) do
    selected = toggle(socket.assigns.selected, path)
    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("navigate", %{"name" => name}, socket) do
    {:noreply, assign_cwd(socket, Path.join(socket.assigns.cwd, name))}
  end

  def handle_event("up", _params, socket) do
    {:noreply, assign_cwd(socket, Path.dirname(socket.assigns.cwd))}
  end

  def handle_event("add_manual", %{"path" => raw}, socket) do
    path = raw |> String.trim() |> Path.expand()

    if path != "" and File.exists?(path) do
      {:noreply,
       socket
       |> assign(:selected, MapSet.put(socket.assigns.selected, path))
       |> assign(:manual_error, nil)}
    else
      {:noreply, assign(socket, :manual_error, "That path does not exist on disk.")}
    end
  end

  def handle_event("submit", _params, socket) do
    Enum.each(socket.assigns.selected, fn path ->
      kind = if File.dir?(path), do: "directory", else: "file"
      TrackedPaths.add(%{path: path, kind: kind})
    end)

    send(self(), {:track_done})
    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket) do
    send(self(), {:track_cancel})
    {:noreply, socket}
  end

  defp toggle(set, path) do
    if MapSet.member?(set, path), do: MapSet.delete(set, path), else: MapSet.put(set, path)
  end

  defp assign_cwd(socket, cwd) do
    entries = list_entries(cwd)
    assign(socket, cwd: cwd, entries: entries)
  end

  # Lists immediate children of `dir` as `%{name, path, dir?}`, folders first
  # then alphabetical. Local filesystem only, so a synchronous `File.ls` is
  # fine (unlike the remote-capable PathBrowser).
  defp list_entries(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.map(fn name ->
          path = Path.join(dir, name)
          %{name: name, path: path, dir?: File.dir?(path)}
        end)
        |> Enum.sort_by(&{not &1.dir?, &1.name})

      _ ->
        []
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(
        :suggestions,
        Suggestions.untracked_in(assigns.suggest_base, assigns.tracked_paths)
      )
      |> assign(:tracked_set, MapSet.new(assigns.tracked_paths))

    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <div class="flex items-center mb-4">
          <h3 class="text-lg font-semibold">Track a path</h3>
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

        <%!-- SUGGESTIONS --%>
        <div :if={@suggestions != []} class="card bg-base-200 p-4 mb-5">
          <div class="flex items-center gap-2 mb-3 text-sm">
            <span>✨</span>
            <b>Not tracked yet</b>
            <span class="opacity-60">
              — {length(@suggestions)} in <span class="font-mono">{@suggest_base}</span>
            </span>
          </div>
          <div class="flex flex-wrap gap-2">
            <button
              :for={path <- @suggestions}
              type="button"
              phx-click="toggle_select"
              phx-value-path={path}
              phx-target={@myself}
              class={[
                "badge badge-lg gap-1 cursor-pointer",
                if(MapSet.member?(@selected, path), do: "badge-accent", else: "badge-outline")
              ]}
            >
              <span>{if MapSet.member?(@selected, path), do: "✓", else: "+"}</span>
              {Path.basename(path)}
            </button>
          </div>
        </div>

        <%!-- BROWSER --%>
        <div class="text-xs font-semibold uppercase tracking-wide opacity-50 mb-1">Or browse</div>
        <div class="text-xs font-mono opacity-60 mb-2 break-all">{@cwd}</div>
        <div class="border border-base-300 rounded max-h-64 overflow-y-auto mb-5">
          <button
            type="button"
            phx-click="up"
            phx-target={@myself}
            class="block w-full text-left px-3 py-1.5 hover:bg-base-200 text-sm"
          >
            ../ (up)
          </button>
          <div
            :for={entry <- @entries}
            class={[
              "flex items-center gap-2 px-3 py-1.5 text-sm border-t border-base-300/40",
              MapSet.member?(@tracked_set, entry.path) && "opacity-50"
            ]}
          >
            <%= if MapSet.member?(@tracked_set, entry.path) do %>
              <span class="size-4 flex-none"></span>
              <span class="flex-none">{entry_icon(entry.dir?)}</span>
              <span class="flex-1 min-w-0 truncate font-mono">{entry.name}</span>
              <span class="badge badge-success badge-sm">tracked</span>
            <% else %>
              <button
                type="button"
                phx-click="toggle_select"
                phx-value-path={entry.path}
                phx-target={@myself}
                class="flex-none"
                aria-label={"Select #{entry.name}"}
              >
                <span class={[
                  "inline-flex items-center justify-center size-4 rounded border",
                  if(MapSet.member?(@selected, entry.path),
                    do: "bg-primary border-primary text-primary-content",
                    else: "border-base-content/40"
                  )
                ]}>
                  {if MapSet.member?(@selected, entry.path), do: "✓", else: ""}
                </span>
              </button>
              <span class="flex-none">{entry_icon(entry.dir?)}</span>
              <%= if entry.dir? do %>
                <button
                  type="button"
                  phx-click="navigate"
                  phx-value-name={entry.name}
                  phx-target={@myself}
                  class="flex-1 min-w-0 truncate font-mono text-left hover:underline"
                >
                  {entry.name}
                </button>
                <span class="opacity-40">›</span>
              <% else %>
                <span class="flex-1 min-w-0 truncate font-mono">{entry.name}</span>
              <% end %>
            <% end %>
          </div>
          <div :if={@entries == []} class="px-3 py-2 text-sm opacity-60">Nothing here.</div>
        </div>

        <%!-- MANUAL --%>
        <div class="text-xs font-semibold uppercase tracking-wide opacity-50 mb-1">
          Or type a path
        </div>
        <form phx-submit="add_manual" phx-target={@myself} class="flex gap-2 mb-1">
          <input
            type="text"
            name="path"
            placeholder="~/.gitconfig"
            class="input input-bordered input-sm flex-1 font-mono"
            autocomplete="off"
          />
          <button type="submit" class="btn btn-sm">Add</button>
        </form>
        <p :if={@manual_error} class="text-xs text-error mb-1">{@manual_error}</p>

        <div class="flex items-center gap-3 mt-5 pt-4 border-t border-base-300">
          <span class="text-sm opacity-70">{selection_summary(@selected)}</span>
          <div class="flex-1"></div>
          <button type="button" phx-click="cancel" phx-target={@myself} class="btn btn-ghost">
            Cancel
          </button>
          <button
            type="button"
            phx-click="submit"
            phx-target={@myself}
            class="btn btn-primary"
            disabled={MapSet.size(@selected) == 0}
          >
            {submit_label(@selected)}
          </button>
        </div>
      </div>
      <label class="modal-backdrop" phx-click="cancel" phx-target={@myself}>Close</label>
    </div>
    """
  end

  defp entry_icon(true), do: "🗂"
  defp entry_icon(false), do: "📄"

  defp selection_summary(selected) do
    case MapSet.size(selected) do
      0 ->
        "No paths selected"

      n ->
        "#{n} #{ngettext_path(n)} selected — " <>
          (selected |> Enum.map(&Path.basename/1) |> Enum.join(", "))
    end
  end

  defp submit_label(selected) do
    case MapSet.size(selected) do
      0 -> "Track"
      n -> "Track #{n} #{ngettext_path(n)}"
    end
  end

  defp ngettext_path(1), do: "path"
  defp ngettext_path(_), do: "paths"
end
