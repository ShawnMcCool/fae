defmodule Fae.Dotfiles.PackageList do
  @moduledoc "Generates this machine's explicitly-installed package manifest."
  alias Fae.Dotfiles.Paths

  @type cmd_fun :: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})

  @default_cmd &System.cmd/3

  @spec generate(cmd_fun()) :: String.t()
  def generate(cmd \\ @default_cmd) do
    {out, 0} = cmd.("pacman", ["-Qqe"], [])
    out |> String.split("\n", trim: true) |> Enum.sort() |> Enum.join("\n")
  end

  @spec write!(Path.t(), cmd_fun()) :: :ok
  def write!(path \\ Paths.manifest_path(), cmd \\ @default_cmd) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, generate(cmd) <> "\n")
    :ok
  end
end
