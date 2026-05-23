defmodule FaeWeb.ArchiveLive.Form do
  @moduledoc """
  Create a new archive (`:new`) or reconfigure an existing one (`:edit`).

  Reconfigure is a clone-and-replace: it builds a brand-new archive from
  the edited values and retires the old one. No bucket objects are
  deleted; if the source / remote folder / destination changed, future
  syncs upload into the new location and the existing files stay put.
  Renaming (the friendly name only) is a separate, in-place action on the
  detail page — not this form.

  Both the Source and Remote folder fields have a folder-picker modal:
  the source browses the local filesystem; the remote browses the chosen
  destination's bucket (one level at a time, async).
  """
  use FaeWeb, :live_view

  alias Fae.Archive
  alias Fae.Archive.Run
  alias Fae.Archive.Runs
  alias Fae.Storage.Destinations
  alias FaeWeb.ArchiveLive.Picker

  @impl true
  def mount(params, _session, socket) do
    socket = assign(socket, destinations: Destinations.list(), picker: nil)
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New archive")
    |> assign(:run, nil)
    |> assign(:form, to_form(Runs.change(%Run{})))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    run = Runs.get!(id)

    # Param-based prefill (string keys) so the folder pickers can merge a
    # selected value back into the form cleanly.
    prefill = %{
      "name" => run.name,
      "source_path" => run.source_path,
      "label" => run.label,
      "destination_id" => run.destination_id
    }

    socket
    |> assign(:page_title, "Reconfigure archive")
    |> assign(:run, run)
    |> assign(:form, to_form(Runs.change(%Run{}, prefill)))
  end

  @impl true
  def handle_event("validate", %{"run" => attrs}, socket) do
    changeset =
      %Run{}
      |> Runs.change(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"run" => attrs}, socket) do
    case socket.assigns.live_action do
      :new -> save_new(socket, attrs)
      :edit -> save_edit(socket, attrs)
    end
  end

  # ── Folder pickers ────────────────────────────────────────────────

  def handle_event("open_local_picker", _params, socket) do
    picker = %{
      kind: :local,
      field: :source_path,
      path: local_start(socket),
      rel: nil,
      dest: nil,
      folders: [],
      loading: true,
      error: nil
    }

    {:noreply, reload_picker(assign(socket, :picker, picker))}
  end

  def handle_event("open_remote_picker", _params, socket) do
    case current_destination(socket) do
      nil ->
        {:noreply, put_flash(socket, :error, "Choose a destination first.")}

      dest ->
        picker = %{
          kind: :remote,
          field: :label,
          path: nil,
          rel: "",
          dest: dest,
          folders: [],
          loading: true,
          error: nil
        }

        {:noreply, reload_picker(assign(socket, :picker, picker))}
    end
  end

  def handle_event("picker_navigate", %{"name" => name}, socket) do
    picker =
      case socket.assigns.picker do
        %{kind: :local, path: path} = p -> %{p | path: Path.join(path, name)}
        %{kind: :remote, rel: rel} = p -> %{p | rel: Picker.remote_join(rel, name)}
      end

    {:noreply, reload_picker(assign(socket, :picker, picker))}
  end

  def handle_event("picker_up", _params, socket) do
    picker =
      case socket.assigns.picker do
        %{kind: :local, path: path} = p -> %{p | path: Picker.local_parent(path)}
        %{kind: :remote, rel: rel} = p -> %{p | rel: Picker.remote_parent(rel)}
      end

    {:noreply, reload_picker(assign(socket, :picker, picker))}
  end

  def handle_event("picker_select", _params, socket) do
    picker = socket.assigns.picker
    value = if picker.kind == :local, do: picker.path, else: picker.rel

    {:noreply, socket |> put_field(picker.field, value) |> assign(:picker, nil)}
  end

  def handle_event("picker_close", _params, socket) do
    {:noreply, assign(socket, :picker, nil)}
  end

  @impl true
  def handle_async(:picker_load, _result, %{assigns: %{picker: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_async(:picker_load, {:ok, {:ok, %{folders: folders}}}, socket) do
    {:noreply,
     assign(socket, :picker, %{socket.assigns.picker | folders: folders, loading: false})}
  end

  def handle_async(:picker_load, {:ok, {:error, reason}}, socket) do
    {:noreply,
     assign(socket, :picker, %{socket.assigns.picker | loading: false, error: inspect(reason)})}
  end

  def handle_async(:picker_load, {:exit, reason}, socket) do
    {:noreply,
     assign(socket, :picker, %{socket.assigns.picker | loading: false, error: inspect(reason)})}
  end

  # ── Internals ─────────────────────────────────────────────────────

  defp save_new(socket, attrs) do
    case Archive.start_archive(attrs) do
      {:ok, run} ->
        {:noreply,
         socket
         |> put_flash(:info, "Archive started.")
         |> push_navigate(to: ~p"/archive/#{run.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(Map.put(changeset, :action, :insert)))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not start archive: #{inspect(reason)}")}
    end
  end

  defp save_edit(socket, attrs) do
    case Archive.replace(socket.assigns.run.id, attrs) do
      {:ok, run} ->
        {:noreply,
         socket
         |> put_flash(:info, "Archive reconfigured.")
         |> push_navigate(to: ~p"/archive/#{run.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(Map.put(changeset, :action, :insert)))}

      {:error, :busy} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Can't reconfigure while a sync is running. Wait for it to finish."
         )}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Archive no longer exists.")
         |> push_navigate(to: ~p"/archive")}
    end
  end

  defp reload_picker(socket) do
    picker = socket.assigns.picker
    socket = assign(socket, :picker, %{picker | loading: true, error: nil})
    start_async(socket, :picker_load, fn -> load_entries(picker) end)
  end

  defp load_entries(%{kind: :local, path: path}), do: Picker.list_local(path)
  defp load_entries(%{kind: :remote, dest: dest, rel: rel}), do: Picker.list_remote(dest, rel)

  defp current_destination(socket) do
    case socket.assigns.form.params["destination_id"] do
      id when is_binary(id) and id != "" -> Destinations.get(id)
      _ -> nil
    end
  end

  defp local_start(socket) do
    case socket.assigns.form.params["source_path"] do
      path when is_binary(path) and path != "" ->
        if File.dir?(path), do: path, else: home()

      _ ->
        home()
    end
  end

  defp home, do: System.user_home() || "/"

  # Merge a picked value into the form params and re-render with it.
  defp put_field(socket, field, value) do
    params = Map.put(socket.assigns.form.params, to_string(field), value)
    changeset = %Run{} |> Runs.change(params) |> Map.put(:action, :validate)
    assign(socket, :form, to_form(changeset))
  end

  defp picker_location(%{kind: :local, path: path}), do: path
  defp picker_location(%{kind: :remote, rel: ""}), do: "(top level)"
  defp picker_location(%{kind: :remote, rel: rel}), do: rel

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <section class="card bg-base-200 p-6 space-y-4 max-w-2xl">
        <h2 class="text-xl font-semibold">{@page_title}</h2>

        <div :if={@live_action == :edit} class="alert alert-warning text-sm">
          <span>
            Reconfiguring replaces this archive with a new one.
            <strong>No files are deleted from the bucket.</strong>
            If you change the source, remote folder, or destination, future syncs upload into the new location — the files already uploaded stay where they are. To just change the name, use Rename instead.
          </span>
        </div>

        <%= if @destinations == [] do %>
          <p class="opacity-75">
            You need a storage destination first. <.link
              navigate={~p"/backups/destinations/new"}
              class="link"
            >Add one</.link>, then come back.
          </p>
        <% else %>
          <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-3">
            <div>
              <label class="label">Name</label>
              <.input
                field={@form[:name]}
                type="text"
                placeholder="Camera Backup"
                class="input input-bordered w-full"
              />
              <p class="text-xs opacity-60 mt-1">
                A friendly name for this archive, shown in the list. Doesn't affect the remote path.
              </p>
            </div>

            <div>
              <label class="label">Source folder</label>
              <div class="flex gap-2 items-center">
                <div class="grow">
                  <.input
                    field={@form[:source_path]}
                    type="text"
                    placeholder="/home/you/Pictures Videos"
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
              <p class="text-xs opacity-60 mt-1">
                An absolute path Fae can read — a local folder, a mounted drive, or a network share. Its tree is mirrored into the bucket.
              </p>
            </div>

            <div>
              <label class="label">Remote folder (optional)</label>
              <div class="flex gap-2 items-center">
                <div class="grow">
                  <.input
                    field={@form[:label]}
                    type="text"
                    placeholder="Pictures Videos"
                    class="input input-bordered w-full font-mono"
                  />
                </div>
                <button
                  type="button"
                  phx-click="open_remote_picker"
                  class="btn btn-square btn-ghost"
                  title="Browse the destination"
                >
                  <.icon name="hero-folder-open" />
                </button>
              </div>
              <p class="text-xs opacity-60 mt-1">
                The folder inside the bucket the source mirrors into, after the destination's path prefix. May contain slashes (e.g. <code>Family Backups (Important)/Pictures Videos</code>). Browse picks an existing folder; type to create a new one.
              </p>
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

            <div class="flex justify-end gap-2 pt-2">
              <.link navigate={~p"/archive"} class="btn btn-ghost">Cancel</.link>
              <button type="submit" class="btn btn-primary">
                {if @live_action == :edit, do: "Reconfigure", else: "Start archive"}
              </button>
            </div>
          </.form>
        <% end %>
      </section>

      <div :if={@picker} class="modal modal-open">
        <div class="modal-box max-w-lg">
          <h3 class="text-lg font-semibold mb-1">
            {if @picker.kind == :local, do: "Choose a source folder", else: "Choose a remote folder"}
          </h3>
          <div class="text-xs opacity-60 font-mono mb-3 break-all">{picker_location(@picker)}</div>

          <div :if={@picker.error} class="alert alert-error text-sm mb-2">{@picker.error}</div>

          <div class="max-h-72 overflow-y-auto border border-base-300 rounded">
            <button
              type="button"
              phx-click="picker_up"
              class="block w-full text-left px-3 py-1.5 hover:bg-base-300 text-sm"
            >
              ../ (up)
            </button>
            <div :if={@picker.loading} class="px-3 py-2 text-sm opacity-60">Loading…</div>
            <button
              :for={folder <- @picker.folders}
              type="button"
              phx-click="picker_navigate"
              phx-value-name={folder}
              class="block w-full text-left px-3 py-1.5 hover:bg-base-300 text-sm font-mono"
            >
              📁 {folder}
            </button>
            <div
              :if={not @picker.loading and @picker.folders == []}
              class="px-3 py-2 text-sm opacity-60"
            >
              No sub-folders here.
            </div>
          </div>

          <div class="flex justify-end gap-2 mt-3">
            <button type="button" phx-click="picker_close" class="btn btn-ghost">Cancel</button>
            <button type="button" phx-click="picker_select" class="btn btn-primary">
              Use this folder
            </button>
          </div>
        </div>
        <label class="modal-backdrop" phx-click="picker_close">Close</label>
      </div>
    </Layouts.app>
    """
  end
end
