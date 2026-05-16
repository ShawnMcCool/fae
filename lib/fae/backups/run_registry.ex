defmodule Fae.Backups.RunRegistry do
  @moduledoc """
  Per-job-id mutex for in-flight runs. Implemented with `Registry`
  (unique keys, no name conflict allowed) so registration is
  process-local — the BEAM auto-unregisters the key when the holder
  process exits, removing the failure mode where a crashed worker
  leaks a lock.

  Used by `Fae.Backups.RunWorker` to implement skip-if-overlapping:
  a second concurrent run for the same job sees `{:error, :overlap}`,
  records a `"skipped"` run row, and returns.
  """

  @registry __MODULE__

  def child_spec(opts) do
    Registry.child_spec([keys: :unique, name: @registry] ++ opts)
  end

  @spec register(String.t()) :: :ok | {:error, :overlap}
  def register(job_id) when is_binary(job_id) do
    case Registry.register(@registry, {:run, job_id}, nil) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _pid}} -> {:error, :overlap}
    end
  end

  @spec unregister(String.t()) :: :ok
  def unregister(job_id) when is_binary(job_id) do
    Registry.unregister(@registry, {:run, job_id})
    :ok
  end

  @spec running?(String.t()) :: boolean()
  def running?(job_id) when is_binary(job_id) do
    Registry.lookup(@registry, {:run, job_id}) != []
  end
end
