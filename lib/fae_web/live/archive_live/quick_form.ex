defmodule FaeWeb.ArchiveLive.QuickForm do
  @moduledoc """
  Quick Archive: one-shot, upload-dated. The operator picks a destination
  and source folder and types a label; Fae drops the tree into a dated
  folder under the destination's quick-archive prefix
  (`<prefix>/<YYYY>/<YYYY-MM-DD>-<slug>`) with the same verification as a
  standard archive. No persistent config, no sync, no reconfigure.

  Distinct from `ArchiveLive.Form`, which configures a curated,
  content-dated, reconfigurable archive.
  """
  use FaeWeb, :live_view

  alias Fae.Archive
  alias Fae.Archive.KeyBuilder
  alias Fae.Archive.Run
  alias Fae.Storage.Destinations
  alias FaeWeb.PathBrowser

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Quick Archive")
     |> assign(:destinations, Destinations.list())
     |> assign(:browser, nil)
     |> assign(:collision, nil)
     |> assign_form(%{})}
  end

  @impl true
  def handle_event("validate", %{"quick" => attrs}, socket) do
    {:noreply, socket |> assign(:collision, nil) |> assign_form(attrs)}
  end

  def handle_event("save", %{"quick" => attrs}, socket) do
    case Archive.start_quick_archive(attrs) do
      {:ok, run} ->
        {:noreply,
         socket
         |> put_flash(:info, "Quick archive started.")
         |> push_navigate(to: ~p"/archive/#{run.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:collision, nil)
         |> assign(:form, to_form(Map.put(changeset, :action, :insert), as: :quick))}

      {:error, :collision, existing} ->
        {:noreply, socket |> assign(:collision, existing) |> assign_form(attrs)}
    end
  end

  def handle_event("open_local_picker", _params, socket) do
    browser = %{
      source: {:local, local_start(socket)},
      mode: :pick,
      show_files: false,
      title: "Choose a source folder",
      return_to: :source_path
    }

    {:noreply, assign(socket, :browser, browser)}
  end

  @impl true
  def handle_info({:path_browser, :selected, return_to, value}, socket) do
    params = Map.put(current_params(socket), to_string(return_to), value)
    {:noreply, socket |> assign(:browser, nil) |> assign_form(params)}
  end

  def handle_info({:path_browser, :closed}, socket) do
    {:noreply, assign(socket, :browser, nil)}
  end

  # ── Internals ─────────────────────────────────────────────────────

  defp assign_form(socket, attrs) do
    changeset =
      %Run{}
      |> Run.quick_form_changeset(attrs)
      |> Map.put(:action, :validate)

    socket
    |> assign(:form, to_form(changeset, as: :quick))
    |> assign(:preview, preview_path(socket.assigns.destinations, attrs))
  end

  defp current_params(socket), do: socket.assigns.form.params

  # The folder the files will land in: <path_prefix>/<dated label>/.
  # nil whenever we can't yet compute it (no destination, no slug-worthy
  # name) so the template can hide the preview.
  defp preview_path(destinations, attrs) do
    with id when is_binary(id) and id != "" <- attrs["destination_id"],
         %{} = destination <- Enum.find(destinations, &(&1.id == id)),
         name when is_binary(name) <- attrs["name"],
         {:ok, label} <- KeyBuilder.quick_label(destination.quick_archive_prefix, today(), name) do
      KeyBuilder.build(destination.path_prefix, label, "") <> "/"
    else
      _ -> nil
    end
  end

  defp today, do: Date.utc_today()

  defp local_start(socket) do
    case current_params(socket)["source_path"] do
      path when is_binary(path) and path != "" ->
        if File.dir?(path), do: path, else: home()

      _ ->
        home()
    end
  end

  defp home, do: System.user_home() || "/"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <section class="card bg-base-200 p-6 space-y-4 max-w-2xl">
        <div>
          <h2 class="text-xl font-semibold">Quick Archive</h2>
          <p class="text-sm opacity-70 mt-1">
            Drop a file or folder into a dated folder — named from today's date and your label —
            with the same verification as a full archive. One shot, no setup.
          </p>
        </div>

        <%= if @destinations == [] do %>
          <p class="opacity-75">
            You need a storage destination first. <.link
              navigate={~p"/destinations/new"}
              class="link"
            >Add one</.link>, then come back.
          </p>
        <% else %>
          <div :if={@collision} class="alert alert-warning text-sm">
            <span>
              You already archived this label to this destination today.
              <.link navigate={~p"/archive/#{@collision.id}"} class="link font-semibold">
                Open the existing archive
              </.link>
              or use a different label.
            </span>
          </div>

          <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-3">
            <div>
              <label class="label">Label</label>
              <.input
                field={@form[:name]}
                type="text"
                placeholder="My Camera Backup"
                class="input input-bordered w-full"
              />
              <p class="text-xs opacity-60 mt-1">
                Names the dated folder and shows in the list. Spaces and capitals are fine — they're slugified for the path.
              </p>
            </div>

            <div>
              <label class="label">Source folder</label>
              <div class="flex gap-2 items-center">
                <div class="grow">
                  <.input
                    field={@form[:source_path]}
                    type="text"
                    placeholder="/home/you/Camera"
                    class="input input-bordered w-full font-mono"
                  />
                </div>
                <button
                  type="button"
                  phx-click="open_local_picker"
                  class="btn btn-square btn-ghost"
                  title="Browse local folders"
                >
                  <.icon name="hero-folder-open" />
                </button>
              </div>
            </div>

            <div>
              <label class="label">Destination</label>
              <.input
                field={@form[:destination_id]}
                type="select"
                prompt="Choose a destination"
                options={Enum.map(@destinations, &{&1.name, &1.id})}
                class="select select-bordered w-full"
              />
            </div>

            <div :if={@preview} class="text-xs opacity-70">
              <span class="opacity-60">Will upload to:</span>
              <code class="ml-1">{@preview}</code>
            </div>

            <div class="flex justify-end gap-2 pt-2">
              <.link navigate={~p"/archive"} class="btn btn-ghost">Cancel</.link>
              <button type="submit" class="btn btn-primary">Start quick archive</button>
            </div>
          </.form>
        <% end %>
      </section>

      <.live_component
        :if={@browser}
        module={PathBrowser}
        id="path-browser"
        tz={@timezone}
        source={@browser.source}
        mode={@browser.mode}
        show_files={@browser.show_files}
        title={@browser.title}
        return_to={@browser.return_to}
      />
    </Layouts.app>
    """
  end
end
