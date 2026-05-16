defmodule Fae.Version do
  @moduledoc """
  Runtime access to the app's version.

  The running version comes from `Application.spec(:fae, :vsn)`, which
  is populated from `mix.exs` at compile time.
  """

  @app :fae

  @doc "Returns the running application's version as a string."
  @spec current_version() :: String.t()
  def current_version do
    case Application.spec(@app, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end

  @doc """
  Compares two SemVer version strings. Leading `v` is stripped from either
  side. Returns `:gt`, `:eq`, `:lt`, or `:error` on parse failure.
  """
  @spec compare_versions(String.t(), String.t()) :: :gt | :eq | :lt | :error
  def compare_versions(remote, local) do
    with {:ok, remote_v} <- parse(remote),
         {:ok, local_v} <- parse(local) do
      Version.compare(remote_v, local_v)
    end
  end

  defp parse(raw) when is_binary(raw) do
    raw
    |> String.trim_leading("v")
    |> Version.parse()
  end
end
