defmodule Fae.Dotfiles.GitHub do
  @moduledoc "Thin wrapper over the `gh` CLI for creating the dotfiles remote."
  @type cmd_fun :: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})
  @default_cmd &System.cmd/3

  @spec available?(cmd_fun()) :: boolean()
  def available?(cmd \\ @default_cmd) do
    System.find_executable("gh") != nil and
      match?({_, 0}, cmd.("gh", ["auth", "status"], stderr_to_stdout: true))
  end

  @spec default_repo_name(String.t() | nil) :: String.t()
  def default_repo_name(host \\ hostname()) do
    slug = host |> String.downcase() |> String.replace(~r/[^a-z0-9-]+/, "-") |> String.trim("-")
    "dotfiles-" <> slug
  end

  @spec create_private_repo(String.t(), cmd_fun()) ::
          {:ok, String.t()} | {:error, atom() | String.t()}
  def create_private_repo(name, cmd \\ @default_cmd) do
    case cmd.("gh", ["repo", "create", name, "--private"], stderr_to_stdout: true) do
      {_, 0} ->
        ssh_url(name, cmd)

      {out, _} ->
        if out =~ "already exists",
          do: {:error, :already_exists},
          else: {:error, String.trim(out)}
    end
  end

  defp ssh_url(name, cmd) do
    case cmd.("gh", ["repo", "view", name, "--json", "sshUrl", "-q", ".sshUrl"], []) do
      {url, 0} -> {:ok, String.trim(url)}
      {out, _} -> {:error, String.trim(out)}
    end
  end

  defp hostname do
    {:ok, h} = :inet.gethostname()
    List.to_string(h)
  end
end
