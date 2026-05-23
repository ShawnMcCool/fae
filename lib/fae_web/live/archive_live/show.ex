defmodule FaeWeb.ArchiveLive.Show do
  @moduledoc """
  Detail view for one archive run: summary, a live progress bar driven
  by `archive:progress`, and the per-file table. Subscribes to both
  `archive:runs` (status) and `archive:progress` (in-flight tally).
  """
  use FaeWeb, :live_view

  alias Fae.Archive
  alias Fae.Archive.Items
  alias Fae.Archive.ProgressServer
  alias Fae.Archive.Runs
  alias FaeWeb.ArchiveLive.View

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      :ok = Archive.subscribe_runs()
      :ok = Archive.subscribe_progress()
    end

    run = Runs.get!(id)

    {:ok,
     socket
     |> assign(:page_title, run_title(run))
     |> assign(:run, run)
     |> assign(:items, Items.list_for_run(id))
     |> assign(:progress, ProgressServer.snapshot(id))
     |> assign(:renaming, false)
     |> assign(:rename_form, nil)}
  end

  @impl true
  def handle_event("sync", _params, socket) do
    _ = Archive.sync(socket.assigns.run.id)
    {:noreply, refresh(socket)}
  end

  def handle_event("delete", _params, socket) do
    {:ok, _} = Runs.delete(socket.assigns.run)
    {:noreply, push_navigate(socket, to: ~p"/archive")}
  end

  def handle_event("open_rename", _params, socket) do
    run = socket.assigns.run

    {:noreply,
     socket
     |> assign(:renaming, true)
     |> assign(:rename_form, to_form(Runs.rename_change(run, %{"name" => run.name})))}
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, :renaming, false)}
  end

  def handle_event("validate_rename", %{"run" => attrs}, socket) do
    changeset =
      socket.assigns.run
      |> Runs.rename_change(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :rename_form, to_form(changeset))}
  end

  def handle_event("rename", %{"run" => attrs}, socket) do
    case Archive.rename(socket.assigns.run.id, attrs) do
      {:ok, _run} ->
        {:noreply,
         socket |> assign(:renaming, false) |> put_flash(:info, "Renamed.") |> refresh()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :rename_form, to_form(Map.put(changeset, :action, :validate)))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not rename: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:run_changed, id}, socket), do: {:noreply, maybe_refresh(socket, id)}
  def handle_info({:run_finished, id, _status}, socket), do: {:noreply, maybe_refresh(socket, id)}

  def handle_info({:archive_progress, id, snapshot}, socket) do
    if id == socket.assigns.run.id do
      {:noreply, assign(socket, :progress, snapshot)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp maybe_refresh(socket, id) do
    if id == socket.assigns.run.id, do: refresh(socket), else: socket
  end

  defp refresh(socket) do
    id = socket.assigns.run.id

    socket
    |> assign(:run, Runs.get!(id))
    |> assign(:items, Items.list_for_run(id))
    |> assign(:progress, ProgressServer.snapshot(id))
  end

  # Live snapshot wins while a run is in flight; otherwise fall back to
  # the durable counters on the run row.
  defp progress_numbers(run, nil) do
    {run.uploaded_files, run.failed_files, run.total_files, run.uploaded_bytes, run.total_bytes}
  end

  defp progress_numbers(_run, snapshot) do
    {snapshot.uploaded_files, snapshot.failed_files, snapshot.total_files,
     snapshot.uploaded_bytes, snapshot.total_bytes}
  end

  defp run_title(%{name: name}) when is_binary(name) and name != "", do: name
  defp run_title(%{label: label}) when is_binary(label) and label != "", do: label
  defp run_title(_run), do: "Archive"

  @impl true
  def render(assigns) do
    {uploaded_files, failed_files, total_files, uploaded_bytes, total_bytes} =
      progress_numbers(assigns.run, assigns.progress)

    assigns =
      assign(assigns,
        uploaded_files: uploaded_files,
        failed_files: failed_files,
        total_files: total_files,
        uploaded_bytes: uploaded_bytes,
        total_bytes: total_bytes,
        percent: View.percent(uploaded_bytes, total_bytes)
      )

    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <section class="card bg-base-200 p-6 space-y-4">
        <div class="flex items-center justify-between gap-4">
          <div>
            <h2 class="text-xl font-semibold">{run_title(@run)}</h2>
            <div class="text-sm opacity-60 font-mono">{@run.source_path}</div>
          </div>
          <div class="flex gap-2">
            <.link navigate={~p"/archive"} class="btn btn-sm btn-ghost">Back</.link>
            <button type="button" phx-click="sync" class="btn btn-sm btn-primary">Sync now</button>
            <button type="button" phx-click="open_rename" class="btn btn-sm btn-ghost">Rename</button>
            <.link
              :if={@run.status not in ["scanning", "uploading"]}
              navigate={~p"/archive/#{@run.id}/edit"}
              class="btn btn-sm btn-ghost"
            >
              Reconfigure
            </.link>
            <button
              type="button"
              phx-click="delete"
              data-confirm="Delete this archive? (Objects already in the bucket are not removed.)"
              class="btn btn-sm btn-error btn-outline"
            >
              Delete
            </button>
          </div>
        </div>

        <div :if={@renaming} class="modal modal-open">
          <div class="modal-box">
            <h3 class="text-lg font-semibold mb-3">Rename archive</h3>
            <.form
              for={@rename_form}
              phx-change="validate_rename"
              phx-submit="rename"
              class="space-y-3"
            >
              <.input field={@rename_form[:name]} type="text" class="input input-bordered w-full" />
              <div class="flex justify-end gap-2">
                <button type="button" phx-click="cancel_rename" class="btn btn-ghost">Cancel</button>
                <button type="submit" class="btn btn-primary">Save</button>
              </div>
            </.form>
          </div>
          <label class="modal-backdrop" phx-click="cancel_rename">Close</label>
        </div>

        <dl class="grid grid-cols-[auto_1fr] gap-x-6 gap-y-1 text-sm">
          <dt class="opacity-60">Status</dt>
          <dd>
            <span class={["badge badge-sm", View.status_badge_class(@run.status)]}>
              {@run.status}
            </span>
          </dd>
          <dt class="opacity-60">Destination</dt>
          <dd>{if @run.destination, do: @run.destination.name, else: "—"}</dd>
          <dt class="opacity-60">Remote folder</dt>
          <dd class="font-mono">{if @run.label == "", do: "(prefix root)", else: @run.label}</dd>
        </dl>

        <div class="space-y-1">
          <div class="flex justify-between text-sm">
            <span>
              {@uploaded_files}/{@total_files} files · {View.human_bytes(@uploaded_bytes)} of {View.human_bytes(
                @total_bytes
              )}
            </span>
            <span :if={@failed_files > 0} class="text-error">{@failed_files} failed</span>
          </div>
          <progress class="progress progress-primary w-full" value={@percent} max="100"></progress>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>File</th>
                <th>Status</th>
                <th>Size</th>
                <th>SHA256</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={item <- @items} id={"item-#{item.id}"}>
                <td class="font-mono text-xs">{item.relative_path}</td>
                <td>
                  <span class={["badge badge-xs", View.status_badge_class(item.status)]}>
                    {item.status}
                  </span>
                  <div
                    :if={item.error_message}
                    class="text-xs text-error truncate max-w-xs"
                    title={item.error_message}
                  >
                    {item.error_message}
                  </div>
                </td>
                <td class="text-xs">
                  {if item.byte_size, do: View.human_bytes(item.byte_size), else: "—"}
                </td>
                <td class="font-mono text-xs opacity-60">{short_sha(item.sha256)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp short_sha(nil), do: "—"
  defp short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 12)
end
