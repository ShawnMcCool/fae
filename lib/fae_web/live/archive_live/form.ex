defmodule FaeWeb.ArchiveLive.Form do
  @moduledoc """
  Create a new archive (`:new`) or reconfigure an existing one (`:edit`).

  Reconfigure is a clone-and-replace: it builds a brand-new archive from
  the edited values and retires the old one. No bucket objects are
  deleted; if the source / remote folder / destination changed, future
  syncs upload into the new location and the existing files stay put.
  Renaming (the friendly name only) is a separate, in-place action on the
  detail page — not this form.
  """
  use FaeWeb, :live_view

  alias Fae.Archive
  alias Fae.Archive.Run
  alias Fae.Archive.Runs
  alias Fae.Storage.Destinations

  @impl true
  def mount(params, _session, socket) do
    socket = assign(socket, :destinations, Destinations.list())
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

    prefill =
      Runs.change(%Run{
        name: run.name,
        source_path: run.source_path,
        label: run.label,
        destination_id: run.destination_id
      })

    socket
    |> assign(:page_title, "Reconfigure archive")
    |> assign(:run, run)
    |> assign(:form, to_form(prefill))
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
              <.input
                field={@form[:source_path]}
                type="text"
                placeholder="/home/you/Pictures Videos"
                class="input input-bordered w-full font-mono"
              />
              <p class="text-xs opacity-60 mt-1">
                An absolute path Fae can read — a local folder, a mounted drive, or a network share. Its tree is mirrored into the bucket.
              </p>
            </div>

            <div>
              <label class="label">Remote folder (optional)</label>
              <.input
                field={@form[:label]}
                type="text"
                placeholder="Pictures Videos"
                class="input input-bordered w-full font-mono"
              />
              <p class="text-xs opacity-60 mt-1">
                The folder inside the bucket the source mirrors into, after the destination's path prefix. May contain slashes (e.g. <code>Family Backups (Important)/Pictures Videos</code>). Leave blank to write straight under the prefix.
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
    </Layouts.app>
    """
  end
end
