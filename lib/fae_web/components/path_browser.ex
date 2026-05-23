defmodule FaeWeb.PathBrowser do
  @moduledoc """
  A reusable folder/file browser modal.

  Render it from a parent LiveView only while a browse is open:

      <.live_component
        :if={@browser}
        module={FaeWeb.PathBrowser} id="path-browser"
        source={@browser.source}        # {:local, path} | {:remote, %Destination{}, rel}
        mode={@browser.mode}            # :pick | :view
        show_files={@browser.show_files}
        title={@browser.title}
        return_to={@browser.return_to}  # opaque tag echoed back on select
      />

  It owns its own navigation state and loads each level with `start_async`.
  It sends two messages to the parent process (a LiveComponent runs in the
  parent's process, so `self()` is the parent LiveView):

    * `{:path_browser, :selected, return_to, value}` — only in `:pick`
      mode; `value` is the chosen local path or remote rel.
    * `{:path_browser, :closed}` — cancel / backdrop / close.
  """
  use FaeWeb, :live_component

  alias FaeWeb.PathBrowser.Source

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if socket.assigns[:initialized?] do
      {:ok, socket}
    else
      {kind, dest, loc} = init_location(assigns.source)

      socket =
        socket
        |> assign(
          kind: kind,
          dest: dest,
          loc: loc,
          folders: [],
          files: [],
          loading: true,
          error: nil,
          initialized?: true
        )
        |> load()

      {:ok, socket}
    end
  end

  defp init_location({:local, path}), do: {:local, nil, path}
  defp init_location({:remote, dest, rel}), do: {:remote, dest, rel}

  @impl true
  def handle_event("navigate", %{"name" => name}, socket) do
    loc = Source.down(socket.assigns.kind, socket.assigns.loc, name)
    {:noreply, socket |> assign(:loc, loc) |> load()}
  end

  def handle_event("up", _params, socket) do
    loc = Source.up(socket.assigns.kind, socket.assigns.loc)
    {:noreply, socket |> assign(:loc, loc) |> load()}
  end

  def handle_event("select", _params, socket) do
    send(self(), {:path_browser, :selected, socket.assigns.return_to, socket.assigns.loc})
    {:noreply, socket}
  end

  def handle_event("close", _params, socket) do
    send(self(), {:path_browser, :closed})
    {:noreply, socket}
  end

  @impl true
  def handle_async(:load, {:ok, {:ok, listing}}, socket) do
    {:noreply, assign(socket, folders: listing.folders, files: listing.files, loading: false)}
  end

  def handle_async(:load, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, loading: false, error: inspect(reason))}
  end

  def handle_async(:load, {:exit, reason}, socket) do
    {:noreply, assign(socket, loading: false, error: inspect(reason))}
  end

  # `start_async` "later wins" semantics is exactly what we want: a rapid
  # sequence of navigations resolves to the last location's listing.
  defp load(socket) do
    source = source_tuple(socket)
    show_files? = socket.assigns.show_files
    socket = assign(socket, loading: true, error: nil)
    start_async(socket, :load, fn -> Source.list(source, show_files?) end)
  end

  defp source_tuple(%{assigns: %{kind: :local, loc: loc}}), do: {:local, loc}
  defp source_tuple(%{assigns: %{kind: :remote, dest: dest, loc: loc}}), do: {:remote, dest, loc}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-lg">
        <h3 class="text-lg font-semibold mb-1">{@title}</h3>
        <div class="text-xs opacity-60 font-mono mb-3 break-all">
          {Source.location_label(@kind, @loc)}
        </div>

        <div :if={@error} class="alert alert-error text-sm mb-2">{@error}</div>

        <div class="max-h-72 overflow-y-auto border border-base-300 rounded">
          <button
            type="button"
            phx-click="up"
            phx-target={@myself}
            class="block w-full text-left px-3 py-1.5 hover:bg-base-300 text-sm"
          >
            ../ (up)
          </button>
          <div :if={@loading} class="px-3 py-2 text-sm opacity-60">Loading…</div>
          <button
            :for={folder <- @folders}
            type="button"
            phx-click="navigate"
            phx-value-name={folder}
            phx-target={@myself}
            class="block w-full text-left px-3 py-1.5 hover:bg-base-300 text-sm font-mono"
          >
            📁 {folder}
          </button>
          <div
            :for={file <- @files}
            class="flex items-center justify-between gap-3 px-3 py-1.5 text-sm font-mono"
          >
            <span class="truncate">📄 {file.name}</span>
            <span class="opacity-60 text-xs whitespace-nowrap">
              {format_size(file.size)} · {format_date(file.last_modified)}
            </span>
          </div>
          <div
            :if={not @loading and @folders == [] and @files == []}
            class="px-3 py-2 text-sm opacity-60"
          >
            Nothing here.
          </div>
        </div>

        <div class="flex justify-end gap-2 mt-3">
          <button type="button" phx-click="close" phx-target={@myself} class="btn btn-ghost">
            {if @mode == :view, do: "Close", else: "Cancel"}
          </button>
          <button
            :if={@mode == :pick}
            type="button"
            phx-click="select"
            phx-target={@myself}
            class="btn btn-primary"
          >
            Use this folder
          </button>
        </div>
      </div>
      <label class="modal-backdrop" phx-click="close" phx-target={@myself}>Close</label>
    </div>
    """
  end

  defp format_size(nil), do: "—"
  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KiB"

  defp format_size(bytes) when bytes < 1_073_741_824,
    do: "#{Float.round(bytes / 1_048_576, 1)} MiB"

  defp format_size(bytes), do: "#{Float.round(bytes / 1_073_741_824, 2)} GiB"

  defp format_date(nil), do: "—"
  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")
end
