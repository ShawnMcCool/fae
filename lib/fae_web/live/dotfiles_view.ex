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
        next_at: next_at(config),
        remote: remote(config)
      },
      groups: group_paths(tracked, now),
      runs: runs
    }
  end

  defp remote(config) do
    url = config.remote_url
    configured? = is_binary(url) and url != ""
    status = remote_status(configured?, config.last_push_ok)

    %{
      configured?: configured?,
      url: if(configured?, do: url, else: nil),
      status: status,
      message: remote_message(status, config.last_push_error)
    }
  end

  defp remote_status(false, _last_push_ok), do: :none
  defp remote_status(true, true), do: :ok
  defp remote_status(true, _last_push_ok), do: :failed

  defp remote_message(:none, _error), do: "Backups are staying local — no remote set"
  defp remote_message(:ok, _error), do: ""

  defp remote_message(:failed, "auth_failed"),
    do: "GitHub rejected the key — check your SSH access"

  defp remote_message(:failed, "not_found"), do: "Repo not found — re-check the URL"
  defp remote_message(:failed, "unreachable"), do: "Couldn't reach GitHub — will retry"
  defp remote_message(:failed, _error), do: "Last push failed — will retry"

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
