defmodule FaeWeb.BackupsLive.JobForm do
  @moduledoc """
  Create or edit a backup job. Renders all schedule and retention
  fields unconditionally; the changeset enforces which ones are
  required for each kind.
  """

  use FaeWeb, :live_view

  alias Fae.Backups.{Destinations, Job, Jobs}

  @impl true
  def mount(params, _session, socket) do
    destinations = Destinations.list()

    {:ok,
     apply_action(assign(socket, :destinations, destinations), socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    job = %Job{
      package_format: "as_is",
      recurrence_kind: "daily",
      retention_strategy: "keep_last_n",
      retention_params: %{"n" => 30},
      enabled: true
    }

    socket
    |> assign(:page_title, "New backup job")
    |> assign(:job, job)
    |> assign(:retention_strategy, "keep_last_n")
    |> assign(:retention_n, 30)
    |> assign(:retention_days, 30)
    |> assign(:retention_gfs_daily, 7)
    |> assign(:retention_gfs_weekly, 4)
    |> assign(:retention_gfs_monthly, 12)
    |> assign(:form, to_form(Jobs.change(job, %{})))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    job = Jobs.get!(id)

    socket
    |> assign(:page_title, "Edit backup job")
    |> assign(:job, job)
    |> assign_retention_from(job)
    |> assign(:form, to_form(Jobs.change(job, %{})))
  end

  defp assign_retention_from(socket, %Job{
         retention_strategy: "keep_last_n",
         retention_params: %{"n" => n}
       }),
       do: socket |> assign(:retention_strategy, "keep_last_n") |> assign(:retention_n, n)

  defp assign_retention_from(socket, %Job{
         retention_strategy: "keep_for_days",
         retention_params: %{"days" => d}
       }),
       do: socket |> assign(:retention_strategy, "keep_for_days") |> assign(:retention_days, d)

  defp assign_retention_from(socket, %Job{retention_strategy: "gfs", retention_params: params}) do
    socket
    |> assign(:retention_strategy, "gfs")
    |> assign(:retention_gfs_daily, params["daily"])
    |> assign(:retention_gfs_weekly, params["weekly"])
    |> assign(:retention_gfs_monthly, params["monthly"])
  end

  defp assign_retention_from(socket, _),
    do:
      socket
      |> assign(:retention_strategy, "keep_last_n")
      |> assign(:retention_n, 30)
      |> assign(:retention_days, 30)
      |> assign(:retention_gfs_daily, 7)
      |> assign(:retention_gfs_weekly, 4)
      |> assign(:retention_gfs_monthly, 12)

  @impl true
  def handle_event("validate", %{"job" => attrs}, socket) do
    attrs = with_retention_params(attrs)

    changeset =
      socket.assigns.job
      |> Jobs.change(attrs)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:retention_strategy, attrs["retention_strategy"])
     |> assign_retention_params_inputs(attrs)
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("save", %{"job" => attrs}, socket) do
    attrs = with_retention_params(attrs)

    case socket.assigns.live_action do
      :new -> save_new(socket, attrs)
      :edit -> save_edit(socket, attrs)
    end
  end

  defp with_retention_params(%{"retention_strategy" => "keep_last_n"} = attrs) do
    Map.put(attrs, "retention_params", %{"n" => to_int(attrs["retention_n"], 30)})
  end

  defp with_retention_params(%{"retention_strategy" => "keep_for_days"} = attrs) do
    Map.put(attrs, "retention_params", %{"days" => to_int(attrs["retention_days"], 30)})
  end

  defp with_retention_params(%{"retention_strategy" => "gfs"} = attrs) do
    Map.put(attrs, "retention_params", %{
      "daily" => to_int(attrs["retention_gfs_daily"], 7),
      "weekly" => to_int(attrs["retention_gfs_weekly"], 4),
      "monthly" => to_int(attrs["retention_gfs_monthly"], 12)
    })
  end

  defp with_retention_params(attrs), do: attrs

  defp to_int(nil, default), do: default
  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  defp assign_retention_params_inputs(socket, attrs) do
    socket
    |> assign(:retention_n, to_int(attrs["retention_n"], socket.assigns.retention_n))
    |> assign(:retention_days, to_int(attrs["retention_days"], socket.assigns.retention_days))
    |> assign(
      :retention_gfs_daily,
      to_int(attrs["retention_gfs_daily"], socket.assigns.retention_gfs_daily)
    )
    |> assign(
      :retention_gfs_weekly,
      to_int(attrs["retention_gfs_weekly"], socket.assigns.retention_gfs_weekly)
    )
    |> assign(
      :retention_gfs_monthly,
      to_int(attrs["retention_gfs_monthly"], socket.assigns.retention_gfs_monthly)
    )
  end

  defp save_new(socket, attrs) do
    case Jobs.create(attrs) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Backup job created.")
         |> push_navigate(to: ~p"/backups")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save_edit(socket, attrs) do
    case Jobs.update(socket.assigns.job, attrs) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Backup job updated.")
         |> push_navigate(to: ~p"/backups")}

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

        <%= if @destinations == [] do %>
          <div class="alert alert-warning">
            No destinations configured. <.link navigate={~p"/backups/destinations/new"} class="link">Create one first</.link>.
          </div>
        <% else %>
          <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-3">
            <div>
              <label class="label">Name</label>
              <.input field={@form[:name]} type="text" class="input input-bordered w-full" />
            </div>

            <div>
              <label class="label">Slug</label>
              <.input
                field={@form[:slug]}
                type="text"
                placeholder="daily-fae-db"
                class="input input-bordered w-full font-mono"
              />
              <p class="text-xs opacity-60 mt-1">
                Lowercase letters, digits, hyphens. Appears in the object key.
              </p>
            </div>

            <div class="grid grid-cols-2 gap-3">
              <div>
                <label class="label">Source kind</label>
                <.input
                  field={@form[:source_kind]}
                  type="select"
                  options={[{"File", "file"}, {"Folder", "folder"}, {"SQLite database", "sqlite"}]}
                  class="select select-bordered w-full"
                />
              </div>
              <div>
                <label class="label">Package format</label>
                <.input
                  field={@form[:package_format]}
                  type="select"
                  options={[{"As-is (single file only)", "as_is"}, {"tar.gz", "tar_gz"}]}
                  class="select select-bordered w-full"
                />
              </div>
            </div>

            <div>
              <label class="label">Source path</label>
              <.input
                field={@form[:source_path]}
                type="text"
                placeholder="/home/user/.local/share/fae/fae.db"
                class="input input-bordered w-full font-mono"
              />
            </div>

            <div>
              <label class="label">Destination</label>
              <.input
                field={@form[:destination_id]}
                type="select"
                options={Enum.map(@destinations, &{&1.name, &1.id})}
                class="select select-bordered w-full"
              />
            </div>

            <div>
              <label class="label">Object-key prefix (optional)</label>
              <.input
                field={@form[:prefix]}
                type="text"
                placeholder="vault"
                class="input input-bordered w-full font-mono"
              />
            </div>

            <div class="divider text-sm">Schedule</div>

            <div class="grid grid-cols-2 gap-3">
              <div>
                <label class="label">Recurrence</label>
                <.input
                  field={@form[:recurrence_kind]}
                  type="select"
                  options={[
                    {"Hourly", "hourly"},
                    {"Daily", "daily"},
                    {"Weekly", "weekly"},
                    {"Monthly", "monthly"}
                  ]}
                  class="select select-bordered w-full"
                />
              </div>
              <div>
                <label class="label">Time of day (HH:MM)</label>
                <.input
                  field={@form[:time_of_day]}
                  type="text"
                  placeholder="03:00"
                  class="input input-bordered w-full font-mono"
                />
              </div>
            </div>

            <div class="grid grid-cols-2 gap-3">
              <div>
                <label class="label">Day of week (0=Sun … 6=Sat, weekly only)</label>
                <.input
                  field={@form[:day_of_week]}
                  type="number"
                  min="0"
                  max="6"
                  class="input input-bordered w-full"
                />
              </div>
              <div>
                <label class="label">Day of month (1-28, monthly only)</label>
                <.input
                  field={@form[:day_of_month]}
                  type="number"
                  min="1"
                  max="28"
                  class="input input-bordered w-full"
                />
              </div>
            </div>

            <div class="divider text-sm">Retention</div>

            <div>
              <label class="label">Strategy</label>
              <.input
                field={@form[:retention_strategy]}
                type="select"
                options={[
                  {"Keep last N", "keep_last_n"},
                  {"Keep for N days", "keep_for_days"},
                  {"Grandfather-father-son", "gfs"}
                ]}
                class="select select-bordered w-full"
              />
            </div>

            <%= case @retention_strategy do %>
              <% "keep_last_n" -> %>
                <div>
                  <label class="label">N</label>
                  <input
                    name="job[retention_n]"
                    type="number"
                    min="0"
                    value={@retention_n}
                    class="input input-bordered w-full"
                  />
                </div>
              <% "keep_for_days" -> %>
                <div>
                  <label class="label">Days</label>
                  <input
                    name="job[retention_days]"
                    type="number"
                    min="0"
                    value={@retention_days}
                    class="input input-bordered w-full"
                  />
                </div>
              <% "gfs" -> %>
                <div class="grid grid-cols-3 gap-3">
                  <div>
                    <label class="label">Daily buckets</label>
                    <input
                      name="job[retention_gfs_daily]"
                      type="number"
                      min="0"
                      value={@retention_gfs_daily}
                      class="input input-bordered w-full"
                    />
                  </div>
                  <div>
                    <label class="label">Weekly buckets</label>
                    <input
                      name="job[retention_gfs_weekly]"
                      type="number"
                      min="0"
                      value={@retention_gfs_weekly}
                      class="input input-bordered w-full"
                    />
                  </div>
                  <div>
                    <label class="label">Monthly buckets</label>
                    <input
                      name="job[retention_gfs_monthly]"
                      type="number"
                      min="0"
                      value={@retention_gfs_monthly}
                      class="input input-bordered w-full"
                    />
                  </div>
                </div>
            <% end %>

            <div class="form-control pt-2">
              <label class="label cursor-pointer justify-start gap-2">
                <.input field={@form[:enabled]} type="checkbox" />
                <span class="label-text">Enabled</span>
              </label>
            </div>

            <div class="flex justify-end gap-2 pt-2">
              <.link navigate={~p"/backups"} class="btn btn-ghost">Cancel</.link>
              <button type="submit" class="btn btn-primary">Save</button>
            </div>
          </.form>
        <% end %>
      </section>
    </Layouts.app>
    """
  end
end
