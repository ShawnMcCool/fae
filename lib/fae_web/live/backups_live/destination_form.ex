defmodule FaeWeb.BackupsLive.DestinationForm do
  @moduledoc """
  Create or edit a backup destination.
  """

  use FaeWeb, :live_view

  alias Fae.Backups.{Destination, Destinations}

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New destination")
    |> assign(:destination, %Destination{})
    |> assign(:form, to_form(Destinations.change(%Destination{}, %{})))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    destination = Destinations.get!(id)

    socket
    |> assign(:page_title, "Edit destination")
    |> assign(:destination, destination)
    |> assign(:form, to_form(Destinations.change(destination, %{})))
  end

  @impl true
  def handle_event("validate", %{"destination" => attrs}, socket) do
    changeset =
      socket.assigns.destination
      |> Destinations.change(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"destination" => attrs}, socket) do
    case socket.assigns.live_action do
      :new -> save_new(socket, attrs)
      :edit -> save_edit(socket, attrs)
    end
  end

  defp save_new(socket, attrs) do
    case Destinations.create(attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Destination created.")
         |> push_navigate(to: ~p"/backups/destinations")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save_edit(socket, attrs) do
    case Destinations.update(socket.assigns.destination, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Destination updated.")
         |> push_navigate(to: ~p"/backups/destinations")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <section class="card bg-base-200 p-6 space-y-4 max-w-2xl">
        <h2 class="text-xl font-semibold">{@page_title}</h2>

        <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-3">
          <div>
            <label class="label">Name</label>
            <.input
              field={@form[:name]}
              type="text"
              placeholder="Hetzner Prod"
              class="input input-bordered w-full"
            />
          </div>

          <div>
            <label class="label">Driver</label>
            <.input
              field={@form[:driver]}
              type="select"
              options={[{"S3-compatible", "s3"}]}
              class="select select-bordered w-full"
            />
          </div>

          <div>
            <label class="label">Endpoint URL</label>
            <.input
              field={@form[:endpoint_url]}
              type="text"
              placeholder="https://fsn1.your-objectstorage.com"
              class="input input-bordered w-full"
            />
            <p class="text-xs opacity-60 mt-1">
              Hetzner format: <code>https://&lt;region&gt;.your-objectstorage.com</code>
            </p>
          </div>

          <div class="grid grid-cols-2 gap-3">
            <div>
              <label class="label">Region</label>
              <.input
                field={@form[:region]}
                type="text"
                placeholder="fsn1"
                class="input input-bordered w-full"
              />
            </div>
            <div>
              <label class="label">Bucket</label>
              <.input
                field={@form[:bucket]}
                type="text"
                placeholder="fae-backups"
                class="input input-bordered w-full"
              />
            </div>
          </div>

          <div class="form-control">
            <label class="label cursor-pointer justify-start gap-2">
              <.input field={@form[:force_path_style]} type="checkbox" />
              <span class="label-text">Force path-style URLs (required for Hetzner)</span>
            </label>
          </div>

          <div>
            <label class="label">Bucket-root path prefix (optional)</label>
            <.input
              field={@form[:path_prefix]}
              type="text"
              placeholder="fae/this-machine"
              class="input input-bordered w-full font-mono"
            />
            <p class="text-xs opacity-60 mt-1">
              Prepended to every object key for jobs using this destination. Leading and trailing slashes are stripped automatically. Leave blank if every job should write at the bucket root.
            </p>
          </div>

          <div>
            <label class="label">Access key ID</label>
            <.input
              field={@form[:access_key_id]}
              type="text"
              class="input input-bordered w-full font-mono"
            />
          </div>

          <div>
            <label class="label">Secret access key</label>
            <.input
              field={@form[:secret_access_key]}
              type="password"
              class="input input-bordered w-full font-mono"
            />
          </div>

          <div class="flex justify-end gap-2 pt-2">
            <.link navigate={~p"/backups/destinations"} class="btn btn-ghost">Cancel</.link>
            <button type="submit" class="btn btn-primary">Save</button>
          </div>
        </.form>
      </section>
    </Layouts.app>
    """
  end
end
