defmodule FaeWeb.ArchiveLive.New do
  @moduledoc """
  Form to start a new archive: pick a source directory, a free-text
  label, and a destination. On success the run is enqueued and the user
  is sent to its detail page to watch progress.
  """
  use FaeWeb, :live_view

  alias Fae.Archive
  alias Fae.Archive.Run
  alias Fae.Archive.Runs
  alias Fae.Storage.Destinations

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "New archive")
     |> assign(:destinations, Destinations.list())
     |> assign(:form, to_form(Runs.change(%Run{})))}
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <section class="card bg-base-200 p-6 space-y-4 max-w-2xl">
        <h2 class="text-xl font-semibold">{@page_title}</h2>

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
              <label class="label">Label (optional)</label>
              <.input
                field={@form[:label]}
                type="text"
                placeholder="Pictures Videos"
                class="input input-bordered w-full"
              />
              <p class="text-xs opacity-60 mt-1">
                A collection name prepended to every object key, after the destination's path prefix. Leave blank to write straight under the prefix.
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
              <button type="submit" class="btn btn-primary">Start archive</button>
            </div>
          </.form>
        <% end %>
      </section>
    </Layouts.app>
    """
  end
end
