defmodule FaeWeb.DotfilesView do
  @moduledoc "Pure shaping of Dotfiles assigns for the LiveView (decision 019)."

  def build(%{config: config, tracked: tracked, runs: runs, now: now}) do
    %{
      health: %{
        enabled: config.enabled,
        interval_seconds: config.interval_seconds,
        last_backup_at: config.last_backup_at,
        last_push_ok: config.last_push_ok,
        last_push_error: config.last_push_error,
        next_at: next_at(config)
      },
      groups: group_paths(tracked, now),
      runs: runs
    }
  end

  defp next_at(%{last_checked_at: nil}), do: nil
  defp next_at(%{last_checked_at: t, interval_seconds: s}), do: DateTime.add(t, s, :second)

  defp group_paths(tracked, _now) do
    tracked
    |> Enum.group_by(&(Path.dirname(&1.path) <> "/"))
    |> Enum.map(fn {header, items} ->
      %{header: header, items: items |> Enum.map(&item/1) |> Enum.sort_by(& &1.name)}
    end)
    |> Enum.sort_by(& &1.header)
  end

  defp item(tp) do
    %{
      name: Path.basename(tp.path),
      path: tp.path,
      kind: tp.kind,
      ignored_count:
        tp.ignore_patterns |> to_string() |> String.split("\n", trim: true) |> length(),
      status: status(tp)
    }
  end

  defp status(tp) do
    cond do
      not File.exists?(tp.path) -> :missing
      is_nil(tp.first_backed_up_at) -> :pending
      true -> :ok
    end
  end
end
