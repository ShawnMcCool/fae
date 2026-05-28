defmodule FaeWeb.DestinationsLive.Index do
  @moduledoc """
  Lists configured storage destinations with edit and delete actions.

  Destinations are shared infrastructure: both Backups and Archive
  write to them, so this lives at the top-level `/destinations` route
  rather than under any single tool.
  """

  use FaeWeb, :live_view

  alias Fae.Storage.Destinations

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Destinations")
     |> assign(:destinations, Destinations.list())}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case Destinations.get(id) do
      nil ->
        {:noreply, socket}

      destination ->
        case Destinations.delete(destination) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(destinations: Destinations.list())
             |> put_flash(:info, "Destination removed.")}

          {:error, _} ->
            {:noreply,
             put_flash(socket, :error, "Could not delete — destination may be in use by jobs.")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <section class="card bg-base-200 p-6 space-y-4">
        <div class="flex items-center justify-between gap-4">
          <h2 class="text-xl font-semibold">Destinations</h2>
          <.link navigate={~p"/destinations/new"} class="btn btn-sm btn-primary">
            New destination
          </.link>
        </div>

        <%= if @destinations == [] do %>
          <p class="opacity-75">
            No destinations yet. <.link navigate={~p"/destinations/new"} class="link">Add one</.link>
            to start creating jobs.
          </p>
        <% else %>
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Driver</th>
                  <th>Endpoint</th>
                  <th>Bucket / region</th>
                  <th class="text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= for dest <- @destinations do %>
                  <tr id={"destination-#{dest.id}"}>
                    <td>{dest.name}</td>
                    <td><span class="badge badge-ghost badge-sm">{dest.driver}</span></td>
                    <td class="font-mono text-xs">{dest.endpoint_url}</td>
                    <td class="font-mono text-xs">{dest.bucket} / {dest.region}</td>
                    <td class="text-right space-x-1">
                      <.link
                        navigate={~p"/destinations/#{dest.id}/edit"}
                        class="btn btn-xs btn-ghost"
                      >
                        Edit
                      </.link>
                      <button
                        type="button"
                        phx-click="delete"
                        phx-value-id={dest.id}
                        data-confirm={"Delete destination '#{dest.name}'?"}
                        class="btn btn-xs btn-error btn-outline"
                      >
                        Delete
                      </button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>
    </Layouts.app>
    """
  end
end
