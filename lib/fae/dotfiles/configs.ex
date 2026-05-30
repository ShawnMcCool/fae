defmodule Fae.Dotfiles.Configs do
  @moduledoc "Read/update the singleton Dotfiles config (id = 1)."
  alias Fae.Dotfiles.{Config, Git}
  alias Fae.{Repo, Topics}

  def get do
    case Repo.get(Config, 1) do
      nil ->
        {:ok, c} = %Config{id: 1} |> Config.changeset(%{}) |> Repo.insert()
        c

      c ->
        c
    end
  end

  def update(attrs) do
    get() |> Config.changeset(attrs) |> Repo.update()
  end

  @doc """
  Validate and set the dotfiles git remote.

  Probes `url` with `Git.ls_remote/2`; on success, reconciles the wired remote
  (`Git.ensure_remote/3`), persists the URL with neutral push state, broadcasts
  `{:dotfiles_changed}`, and returns `{:ok, config}`. On a validation failure the
  classified reason is returned and `remote_url` is left unchanged.
  """
  @spec set_remote(String.t(), keyword()) :: {:ok, Config.t()} | {:error, atom()}
  def set_remote(url, opts \\ []) do
    case Git.ls_remote(url, opts) do
      :ok ->
        :ok = Git.ensure_remote(get().remote_name, url, opts)

        {:ok, config} =
          update(%{remote_url: url, last_push_ok: true, last_push_error: nil})

        broadcast_changed()
        {:ok, config}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp broadcast_changed do
    Phoenix.PubSub.broadcast(Fae.PubSub, Topics.dotfiles_status(), {:dotfiles_changed})
  end
end
