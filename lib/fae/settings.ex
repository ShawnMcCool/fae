defmodule Fae.Settings do
  @moduledoc """
  Cross-cutting key/value settings store. Single SQLite table; values
  are arbitrary maps.

  Reads and writes go directly to the Repo (no `:persistent_term` cache
  — the table is small and reads are cheap on local SQLite). Writes
  broadcast `{:setting_changed, key, value}` on `Phoenix.PubSub` topic
  `"settings"`; `value` is `nil` for deletions.
  """

  import Ecto.Query, only: [from: 2]

  alias Fae.Repo
  alias Fae.Settings.Entry

  @topic "settings"

  @type attrs :: %{optional(atom() | binary()) => term()}

  @doc "PubSub topic for settings change events."
  def topic, do: @topic

  @doc "Subscribe the calling process to settings change events."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Fae.PubSub, @topic)
  end

  @spec list_entries() :: [Entry.t()]
  def list_entries do
    Repo.all(Entry)
  end

  @spec get_by_key(String.t()) :: {:ok, Entry.t() | nil}
  def get_by_key(key) when is_binary(key) do
    {:ok, Repo.get_by(Entry, key: key)}
  end

  @spec get_by_keys([String.t()]) :: %{String.t() => Entry.t()}
  def get_by_keys(keys) when is_list(keys) do
    from(entry in Entry, where: entry.key in ^keys)
    |> Repo.all()
    |> Map.new(fn entry -> {entry.key, entry} end)
  end

  @doc """
  Insert or update an entry by key. Idempotent.
  """
  @spec put(String.t(), map()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def put(key, value) when is_binary(key) and is_map(value) do
    result =
      case Repo.get_by(Entry, key: key) do
        nil ->
          Repo.insert(Entry.upsert_changeset(%{key: key, value: value}))

        existing ->
          Repo.update(Entry.update_changeset(existing, %{value: value}))
      end

    broadcast_change(result)
    result
  end

  @spec delete(String.t()) :: :ok
  def delete(key) when is_binary(key) do
    case Repo.get_by(Entry, key: key) do
      nil ->
        :ok

      entry ->
        {:ok, _} = Repo.delete(entry)
        broadcast(key, nil)
        :ok
    end
  end

  defp broadcast_change({:ok, %Entry{key: key, value: value}}), do: broadcast(key, value)
  defp broadcast_change(_), do: :ok

  defp broadcast(key, value) do
    Phoenix.PubSub.broadcast(Fae.PubSub, @topic, {:setting_changed, key, value})
  end
end
