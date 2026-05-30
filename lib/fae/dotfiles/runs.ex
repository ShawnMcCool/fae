defmodule Fae.Dotfiles.Runs do
  @moduledoc "Durable history of backup runs."
  import Ecto.Query, only: [from: 2]
  alias Fae.Dotfiles.Run
  alias Fae.Repo

  def create_started do
    %Run{}
    |> Run.start_changeset(%{status: "running", started_at: DateTime.utc_now()})
    |> Repo.insert()
  end

  def finalize(%Run{} = run, attrs) do
    run |> Run.finish_changeset(attrs) |> Repo.update()
  end

  def last, do: Repo.one(from r in Run, order_by: [desc: r.started_at], limit: 1)

  def list_recent(limit \\ 20) do
    Repo.all(from r in Run, order_by: [desc: r.started_at], limit: ^limit)
  end
end
