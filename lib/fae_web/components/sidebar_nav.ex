defmodule FaeWeb.SidebarNav do
  @moduledoc """
  Static configuration for the left-rail sidebar. One canonical list
  of groups → items, consumed by `FaeWeb.Layouts` when rendering the
  rail.

  Each group renders as a column of icon buttons, separated by a thin
  divider. Every group carries an `:anchor`: `:top` groups stack from
  the top of the rail (Dashboard, the tools, then shared Destinations),
  while `:bottom` groups are pinned to the foot as system chrome
  (Updates, Settings). New tools register by appending a group (or an
  item to an existing group) — no DB, no migrations.
  """

  @type anchor :: :top | :bottom
  @type item :: %{path: String.t(), label: String.t(), icon: String.t()}
  @type group :: %{anchor: anchor(), items: [item()]}

  @groups [
    %{
      anchor: :top,
      items: [
        %{path: "/", label: "Dashboard", icon: "hero-home"}
      ]
    },
    %{
      anchor: :top,
      items: [
        %{path: "/backups", label: "Backup jobs", icon: "hero-archive-box"},
        %{path: "/archive", label: "Archive", icon: "hero-cloud-arrow-up"}
      ]
    },
    %{
      anchor: :top,
      items: [
        %{path: "/destinations", label: "Destinations", icon: "hero-server"}
      ]
    },
    %{
      anchor: :bottom,
      items: [
        %{path: "/update", label: "Updates", icon: "hero-arrow-down-tray"},
        %{path: "/settings", label: "Settings", icon: "hero-cog-6-tooth"}
      ]
    }
  ]

  @doc "Canonical ordered list of every sidebar group."
  @spec groups() :: [group()]
  def groups, do: @groups

  @doc "Sidebar groups anchored to `:top` or `:bottom` of the rail, in order."
  @spec groups(anchor()) :: [group()]
  def groups(anchor), do: Enum.filter(@groups, &(&1.anchor == anchor))

  @doc """
  True when the rail item at `item_path` should be highlighted for
  `current_path`. The home route (`"/"`) matches only on an exact
  equality; every other item matches when `current_path` equals it or
  is nested under it (so `/backups/<id>/edit` highlights Backup jobs).

  Rail items are never prefixes of one another, so a plain prefix test
  is unambiguous. If a future item ever nests under another, this would
  need a longest-match tiebreak.
  """
  @spec active?(String.t() | nil, String.t()) :: boolean()
  def active?(nil, _item_path), do: false
  def active?(current_path, item_path), do: matches?(current_path, item_path)

  defp matches?(current, "/"), do: current == "/"
  defp matches?(current, path), do: current == path or String.starts_with?(current, path <> "/")
end
