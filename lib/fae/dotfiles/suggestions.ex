defmodule Fae.Dotfiles.Suggestions do
  @moduledoc "Suggests config entries under a base dir not yet tracked."
  def default_base, do: Path.join(System.user_home!(), ".config")

  def untracked_in(base \\ default_base(), tracked_paths) do
    tracked = MapSet.new(tracked_paths)

    case File.ls(base) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(base, &1))
        |> Enum.reject(&MapSet.member?(tracked, &1))
        |> Enum.sort()

      _ ->
        []
    end
  end
end
