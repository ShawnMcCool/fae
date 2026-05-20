defmodule Fae.Backups.RunPipeline do
  @moduledoc """
  Orchestrates one execution of a backup job:

      start run row → snapshot source → package → upload → record
      success → retention sweep → cleanup

  Cleanups always run (in `try/after`) regardless of success or
  failure. Retention sweep is best-effort — failures are logged but
  do not flip a successful run to failed.

  ## Outcome classification

  Errors are classified as **transient** (DNS, TCP, TLS, timeout,
  HTTP 5xx, HTTP 429) or **permanent** (auth, missing source, 4xx,
  unknown atom). The pipeline writes the run row according to:

    * success                                  → `"success"`
    * permanent error                          → `"failed"`
    * transient error, more attempts remaining → `"snoozed"`
    * transient error, final attempt           → `"failed"`

  The caller controls whether this is the final attempt via the
  `:last_attempt?` option (default `true`). The Oban worker passes
  `false` until `attempt == max_attempts`.

  ## Return values

    * `{:ok, run}`           — success
    * `{:snoozed, reason}`   — transient, will be retried by caller
    * `{:failed, reason}`    — terminal, do not retry

  ## PubSub

  Broadcasts on `Fae.Topics.backups_runs/0`:

    * `{:run_started, run_id}`
    * `{:run_finished, run_id, :success | :failed | :snoozed, info_or_reason}`
  """

  require Logger

  alias Fae.Backups.{Drivers, Job, Jobs, Packager, Retention, Runs, Sources}
  alias Fae.Topics

  @type result ::
          {:ok, Fae.Backups.Run.t()}
          | {:snoozed, term()}
          | {:failed, term()}

  @doc """
  Runs the job. See moduledoc for return values and the
  `:last_attempt?` option (default `true`).
  """
  @spec run(Job.t(), keyword()) :: result()
  def run(%Job{} = job, opts \\ []) do
    last_attempt? = Keyword.get(opts, :last_attempt?, true)
    job = ensure_destination_loaded(job)
    started_at = Fae.Clock.now()
    {:ok, run} = Runs.start(job.id, started_at)
    broadcast({:run_started, run.id})

    result = pipeline(job, run)
    finish(run, result, last_attempt?)
  end

  @doc """
  Classifies an error term as `:transient` (worth retrying) or
  `:permanent` (retrying won't help). Transient: network/transport
  errors, timeouts, HTTP 5xx, HTTP 429. Permanent: everything else.
  """
  @spec classify_error(term()) :: :transient | :permanent
  def classify_error(%Finch.TransportError{}), do: :transient
  def classify_error(%Mint.TransportError{}), do: :transient
  def classify_error(%Finch.HTTPError{}), do: :transient
  def classify_error(:timeout), do: :transient
  def classify_error({:timeout, _}), do: :transient
  def classify_error({:network, _}), do: :transient
  def classify_error({:s3_error, status, _}) when status >= 500, do: :transient
  def classify_error({:s3_error, 429, _}), do: :transient
  def classify_error(_), do: :permanent

  defp pipeline(job, run) do
    with {:ok, src_kind, src_path, src_cleanup} <- Sources.snapshot(job) do
      try do
        with_packaged(job, src_kind, src_path, fn upload_path, ext ->
          upload_and_record(job, run, upload_path, ext)
        end)
      after
        safely(src_cleanup)
      end
    end
  end

  defp with_packaged(job, src_kind, src_path, continuation) do
    case Packager.package(src_kind, src_path, job.package_format) do
      {:ok, upload_path, ext, pkg_cleanup} ->
        try do
          continuation.(upload_path, ext)
        after
          safely(pkg_cleanup)
        end

      {:error, _} = error ->
        error
    end
  end

  defp upload_and_record(job, run, upload_path, ext) do
    driver = Drivers.driver_for(job.destination)
    object_key = build_object_key(job, run, ext)

    case driver.put(job.destination, object_key, upload_path) do
      {:ok, %{byte_size: bytes, sha256: sha}} ->
        apply_retention(job, driver)
        {:ok, %{object_key: object_key, byte_size: bytes, sha256: sha}}

      {:error, _} = error ->
        error
    end
  end

  defp apply_retention(job, driver) do
    prefix = object_prefix(job)

    with {:ok, objects} <- driver.list(job.destination, prefix) do
      {_keep, to_delete} =
        Retention.partition(
          objects,
          job.retention_strategy,
          job.retention_params,
          Fae.Clock.now()
        )

      Enum.each(to_delete, fn obj ->
        case driver.delete(job.destination, obj.key) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Retention delete failed for #{obj.key}: #{inspect(reason)}")
        end
      end)

      :ok
    else
      {:error, reason} ->
        Logger.warning("Retention list failed: #{inspect(reason)}")
        :ok
    end
  end

  defp build_object_key(job, run, ext) do
    ts =
      run.started_at
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601(:basic)

    "#{object_prefix(job)}#{ts}.#{ext}"
  end

  @doc false
  def object_prefix(%Job{} = job) do
    [destination_path_prefix(job), trim_segment(job.prefix), job.slug]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("/")
    |> Kernel.<>("/")
  end

  defp destination_path_prefix(%Job{destination: %{path_prefix: prefix}}) when is_binary(prefix),
    do: trim_segment(prefix)

  defp destination_path_prefix(_job), do: ""

  defp trim_segment(nil), do: ""
  defp trim_segment(value), do: value |> to_string() |> String.trim() |> String.trim("/")

  defp finish(run, {:ok, %{object_key: object_key, byte_size: bytes, sha256: sha} = info}, _last?) do
    {:ok, finished} =
      Runs.finish(run, %{
        finished_at: Fae.Clock.now(),
        status: "success",
        object_key: object_key,
        byte_size: bytes,
        sha256: sha
      })

    broadcast({:run_finished, finished.id, :success, info})
    {:ok, finished}
  end

  defp finish(run, {:error, reason}, last_attempt?) do
    case {classify_error(reason), last_attempt?} do
      {:transient, false} -> finish_snoozed(run, reason)
      _ -> finish_failed(run, reason)
    end
  end

  defp finish_failed(run, reason) do
    {:ok, finished} =
      Runs.finish(run, %{
        finished_at: Fae.Clock.now(),
        status: "failed",
        error_message: format_error(reason)
      })

    broadcast({:run_finished, finished.id, :failed, reason})
    {:failed, reason}
  end

  defp finish_snoozed(run, reason) do
    {:ok, finished} =
      Runs.finish(run, %{
        finished_at: Fae.Clock.now(),
        status: "snoozed",
        error_message: format_error(reason)
      })

    broadcast({:run_finished, finished.id, :snoozed, reason})
    {:snoozed, reason}
  end

  defp format_error(reason) do
    inspect(reason, pretty: true, limit: :infinity, printable_limit: 4096)
    |> String.slice(0, 4096)
  end

  defp ensure_destination_loaded(%Job{destination: %Ecto.Association.NotLoaded{}} = job) do
    Jobs.get!(job.id)
  end

  defp ensure_destination_loaded(%Job{} = job), do: job

  defp safely(fun) do
    fun.()
  rescue
    e ->
      Logger.warning("Backup cleanup failed: #{inspect(e)}")
      :ok
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Fae.PubSub, Topics.backups_runs(), message)
  end
end
