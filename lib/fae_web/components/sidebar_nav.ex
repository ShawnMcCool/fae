defmodule FaeWeb.SidebarNav do
  @moduledoc """
  Static configuration for the left-rail sidebar. One canonical list
  of groups → items, consumed by `FaeWeb.Layouts` when rendering the
  rail.

  Each group is rendered as a column of icon buttons; groups are
  separated by a thin divider. New tools register by appending a
  group (or item to an existing group) — no DB, no migrations.
  """

  @type item :: %{path: String.t(), label: String.t(), icon: String.t()}
  @type group :: %{items: [item()]}

  @groups [
    %{
      items: [
        %{path: "/", label: "Dashboard", icon: "hero-home"}
      ]
    },
    %{
      items: [
        %{path: "/backups", label: "Backup jobs", icon: "hero-archive-box"},
        %{path: "/backups/destinations", label: "Destinations", icon: "hero-server"}
      ]
    },
    %{
      items: [
        %{path: "/archive", label: "Archive", icon: "hero-cloud-arrow-up"}
      ]
    },
    %{
      items: [
        %{path: "/update", label: "Updates", icon: "hero-arrow-down-tray"}
      ]
    }
  ]

  @doc "Canonical ordered list of sidebar groups."
  @spec groups() :: [group()]
  def groups, do: @groups

  @doc "Flat list of every nav item across every group."
  @spec items() :: [item()]
  def items, do: Enum.flat_map(@groups, & &1.items)

  @doc """
  True when `item_path` is the most specific nav item matching
  `current_path`. The home route (`"/"`) only matches exactly; every
  other path matches if `current_path` equals it or is nested under
  it. When two items both prefix-match, the longer path wins (so
  `/backups/destinations` lights up Destinations, not Backup jobs).
  """
  @spec active?(String.t() | nil, String.t()) :: boolean()
  def active?(nil, _item_path), do: false

  def active?(current_path, item_path) do
    matches?(current_path, item_path) and
      not Enum.any?(items(), fn other ->
        other.path != item_path and
          String.length(other.path) > String.length(item_path) and
          matches?(current_path, other.path)
      end)
  end

  defp matches?(current, "/"), do: current == "/"
  defp matches?(current, path), do: current == path or String.starts_with?(current, path <> "/")
end
