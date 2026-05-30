defmodule FaeWeb.DotfilesLive.RemoteSetupComponent do
  @moduledoc """
  The foolproof, step-by-step "Set up a remote" modal.

  Two routes, in plain language:

    * **Create a private GitHub repo for me** — only offered when the `gh`
      CLI is installed and authed. Pre-fills the default repo name and, on
      submit, creates the repo and wires it as the remote.
    * **I already have a repo — paste its URL** — validates the pasted URL
      against the real remote (`git ls-remote`) before saving.

  Either route ends on a **Done** confirmation, after which the parent is
  notified with `{:remote_done}` to close the modal and reload.

  External effects are injected as function assigns so tests stay off the
  network and the real `gh` CLI:

    * `github_available?` — boolean (default `GitHub.available?/0`)
    * `default_repo_name` — string (default `GitHub.default_repo_name/0`)
    * `create_repo_fn` — `(name -> {:ok, url} | {:error, reason})`
      (default `GitHub.create_private_repo/1`)
    * `set_remote_fn` — `(url -> {:ok, config} | {:error, reason})`
      (default `Configs.set_remote/1`)
  """

  use FaeWeb, :live_component

  alias Fae.Dotfiles.{Configs, GitHub}

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:github_available?, fn -> GitHub.available?() end)
      |> assign_new(:default_repo_name, fn -> GitHub.default_repo_name() end)
      |> assign_new(:create_repo_fn, fn -> &GitHub.create_private_repo/1 end)
      |> assign_new(:set_remote_fn, fn -> &Configs.set_remote/1 end)
      |> assign_new(:step, fn -> :choose end)
      |> assign_new(:error, fn -> nil end)
      |> assign_new(:busy?, fn -> false end)
      |> assign_new(:remote_url, fn -> nil end)

    {:ok, socket}
  end

  @impl true
  def handle_event("choose_create", _params, socket) do
    {:noreply, assign(socket, step: :create, error: nil)}
  end

  def handle_event("choose_paste", _params, socket) do
    {:noreply, assign(socket, step: :paste, error: nil)}
  end

  def handle_event("back", _params, socket) do
    {:noreply, assign(socket, step: :choose, error: nil)}
  end

  def handle_event("create_repo", %{"name" => name}, socket) do
    name = String.trim(name)

    case socket.assigns.create_repo_fn.(name) do
      {:ok, url} -> finish_with_remote(socket, url)
      {:error, reason} -> {:noreply, assign(socket, error: create_error_message(reason))}
    end
  end

  def handle_event("save_url", %{"url" => url}, socket) do
    finish_with_remote(socket, String.trim(url))
  end

  def handle_event("close", _params, socket) do
    send(self(), {:remote_done})
    {:noreply, socket}
  end

  defp finish_with_remote(socket, url) do
    case socket.assigns.set_remote_fn.(url) do
      {:ok, _config} ->
        {:noreply, assign(socket, step: :done, remote_url: url, error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error: set_remote_error_message(reason))}
    end
  end

  @doc "Friendly inline message for a `create_private_repo` failure."
  def create_error_message(:already_exists),
    do: "That name is taken — pick another or paste its URL instead."

  def create_error_message(message) when is_binary(message),
    do: "Couldn't create the repo: #{message}"

  def create_error_message(_reason), do: "Couldn't create the repo — try again."

  @doc "Friendly inline message for a `Configs.set_remote` failure."
  def set_remote_error_message(:auth_failed),
    do: "GitHub rejected the key — check your SSH access."

  def set_remote_error_message(:not_found),
    do: "That repo wasn't found — double-check the URL."

  def set_remote_error_message(:unreachable),
    do: "Couldn't reach it — check your connection and try again."

  def set_remote_error_message(_reason),
    do: "Couldn't save that remote — try again."

  @impl true
  def render(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-xl">
        <div class="flex items-center mb-4">
          <h3 class="text-lg font-semibold">{heading(@step)}</h3>
          <div class="flex-1"></div>
          <button
            type="button"
            phx-click="close"
            phx-target={@myself}
            class="btn btn-ghost btn-sm btn-square"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <p :if={@error} class="alert alert-error text-sm mb-4">{@error}</p>

        <%!-- STEP 1: CHOOSE --%>
        <div :if={@step == :choose} class="space-y-3">
          <p class="text-sm opacity-70">
            A remote is where your backups are pushed. Pick how you'd like to set one up.
          </p>

          <button
            :if={@github_available?}
            type="button"
            phx-click="choose_create"
            phx-target={@myself}
            class="card bg-base-200 hover:bg-base-300 w-full p-4 text-left"
          >
            <div class="font-medium">Create a private GitHub repo for me</div>
            <div class="text-sm opacity-60">
              I'll make <span class="font-mono">{@default_repo_name}</span> on your GitHub account.
            </div>
          </button>

          <button
            type="button"
            phx-click="choose_paste"
            phx-target={@myself}
            class="card bg-base-200 hover:bg-base-300 w-full p-4 text-left"
          >
            <div class="font-medium">I already have a repo — paste its URL.</div>
            <div class="text-sm opacity-60">Works with GitHub or any other git host.</div>
          </button>

          <p :if={not @github_available?} class="text-xs opacity-60">
            Install the GitHub CLI (gh) to create one automatically.
          </p>
        </div>

        <%!-- STEP 2a: CREATE --%>
        <form
          :if={@step == :create}
          phx-submit="create_repo"
          phx-target={@myself}
          class="space-y-4"
        >
          <p class="text-sm opacity-70">
            I'll create a private repository on your GitHub account and use it as the remote.
          </p>
          <label class="form-control">
            <span class="label-text text-sm mb-1">Repository name</span>
            <input
              type="text"
              name="name"
              value={@default_repo_name}
              class="input input-bordered font-mono"
              autocomplete="off"
            />
          </label>
          <div class="flex items-center gap-3 pt-2">
            <button type="button" phx-click="back" phx-target={@myself} class="btn btn-ghost btn-sm">
              ← Back
            </button>
            <div class="flex-1"></div>
            <button type="submit" class="btn btn-primary">Create repository</button>
          </div>
        </form>

        <%!-- STEP 2b: PASTE --%>
        <form
          :if={@step == :paste}
          phx-submit="save_url"
          phx-target={@myself}
          class="space-y-4"
        >
          <p class="text-sm opacity-70">
            Paste the repository URL. I'll check it's reachable before saving.
          </p>
          <label class="form-control">
            <span class="label-text text-sm mb-1">Repository URL</span>
            <input
              type="text"
              name="url"
              placeholder="git@github.com:you/dotfiles.git"
              class="input input-bordered font-mono"
              autocomplete="off"
            />
          </label>
          <div class="flex items-center gap-3 pt-2">
            <button type="button" phx-click="back" phx-target={@myself} class="btn btn-ghost btn-sm">
              ← Back
            </button>
            <div class="flex-1"></div>
            <button type="submit" class="btn btn-primary">Check &amp; save</button>
          </div>
        </form>

        <%!-- STEP 3: DONE --%>
        <div :if={@step == :done} class="space-y-4">
          <p class="text-sm">
            ✓ Remote set: <span class="font-mono break-all">{@remote_url}</span>
            — reachable. Your backups will push from here on.
          </p>
          <div class="flex">
            <div class="flex-1"></div>
            <button type="button" phx-click="close" phx-target={@myself} class="btn btn-primary">
              Close
            </button>
          </div>
        </div>
      </div>
      <label class="modal-backdrop" phx-click="close" phx-target={@myself}>Close</label>
    </div>
    """
  end

  @doc "The numbered step heading shown in the modal."
  def heading(:choose), do: "Set up a remote — Step 1 of 2"
  def heading(:create), do: "Set up a remote — Step 2 of 2"
  def heading(:paste), do: "Set up a remote — Step 2 of 2"
  def heading(:done), do: "Set up a remote — Done"
end
