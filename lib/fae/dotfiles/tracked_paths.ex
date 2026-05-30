defmodule Fae.Dotfiles.TrackedPaths do
  @moduledoc "CRUD for tracked paths; writes broadcast {:dotfiles_changed}."
  import Ecto.Query, only: [from: 2]
  alias Fae.Dotfiles.TrackedPath
  alias Fae.{Repo, Topics}

  def list, do: Repo.all(from t in TrackedPath, order_by: [asc: t.path])

  def add(attrs) do
    %TrackedPath{} |> TrackedPath.changeset(attrs) |> Repo.insert() |> broadcast()
  end

  def remove(%TrackedPath{} = tp) do
    {:ok, _} = Repo.delete(tp)
    broadcast({:ok, tp})
    :ok
  end

  def set_ignores(%TrackedPath{} = tp, patterns) do
    tp |> TrackedPath.changeset(%{ignore_patterns: patterns}) |> Repo.update() |> broadcast()
  end

  def mark_first_backup(paths, at) when is_list(paths) do
    Repo.update_all(
      from(t in TrackedPath, where: t.path in ^paths and is_nil(t.first_backed_up_at)),
      set: [first_backed_up_at: at]
    )

    :ok
  end

  defp broadcast({:ok, _} = res) do
    Phoenix.PubSub.broadcast(Fae.PubSub, Topics.dotfiles_status(), {:dotfiles_changed})
    res
  end

  defp broadcast(other), do: other
end
