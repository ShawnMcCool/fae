defmodule Fae.Dotfiles.Configs do
  @moduledoc "Read/update the singleton Dotfiles config (id = 1)."
  alias Fae.Dotfiles.Config
  alias Fae.Repo

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
end
