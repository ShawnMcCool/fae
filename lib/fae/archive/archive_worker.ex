defmodule Fae.Archive.ArchiveWorker do
  @moduledoc """
  Runs one archive: scan the source tree, record an item per file, then
  stream every pending file up with bounded parallelism, recording each
  result. Idempotent — re-running (resume after a restart, or a
  retry-failed) re-scans without duplicating items and only uploads
  files still pending, so completed files are skipped.

  The upload Tasks do network I/O only and return their result; this
  worker process performs all DB writes (keeping them inside the Oban /
  test process and out of the spawned Tasks).
  """
  use Oban.Worker,
    queue: :archive,
    max_attempts: 3,
    unique: [keys: [:run_id], states: [:available, :scheduled, :executing, :retryable]]

  require Logger

  alias Fae.Archive.Items
  alias Fae.Archive.KeyBuilder
  alias Fae.Archive.ProgressServer
  alias Fae.Archive.Runs
  alias Fae.Archive.Scanner
  alias Fae.Storage.Drivers

  # Upload several files at once to keep the uplink saturated; the part
  # streaming inside each file stays sequential.
  @upload_concurrency 4
  # A single very large file may take a long time; don't time it out.
  @task_timeout :timer.hours(6)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
    case Runs.get(run_id) do
      nil -> :ok
      run -> archive(run)
    end
  end

  defp archive(run) do
    {:ok, run} = Runs.mark_scanning(run)

    case scan_and_record(run) do
      {:ok, total_files, total_bytes} ->
        upload(run, total_files, total_bytes)

      {:error, reason} ->
        {:ok, _} = Runs.mark_failed(run, format_error(reason))
        :ok
    end
  end

  defp scan_and_record(run) do
    items =
      run.source_path
      |> Scanner.scan()
      |> Enum.map(fn %{relative_path: relative_path, byte_size: byte_size} ->
        %{
          relative_path: relative_path,
          object_key: KeyBuilder.build(run.destination.path_prefix, run.label, relative_path),
          byte_size: byte_size
        }
      end)

    Items.insert_scanned(run.id, items)

    total_bytes = Enum.reduce(items, 0, fn item, acc -> acc + item.byte_size end)
    {:ok, length(items), total_bytes}
  rescue
    error -> {:error, error}
  end

  defp upload(run, total_files, total_bytes) do
    ProgressServer.start_run(run.id, total_files, total_bytes, Items.counts_for_run(run.id))
    {:ok, run} = Runs.mark_uploading(run, total_files, total_bytes)

    driver = Drivers.driver_for(run.destination)

    Fae.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      Items.pending_for_run(run.id),
      fn item -> {item, upload_item(driver, run, item)} end,
      max_concurrency: @upload_concurrency,
      ordered: false,
      timeout: @task_timeout,
      on_timeout: :kill_task
    )
    |> Enum.each(&handle_result(&1, run.id))

    {:ok, _} = Runs.finalize(run, Items.counts_for_run(run.id))
    ProgressServer.finish_run(run.id)
    :ok
  end

  defp handle_result({:ok, {item, {:ok, result}}}, run_id) do
    {:ok, _} = Items.record_uploaded(item, result)
    ProgressServer.record_uploaded(run_id, result.byte_size)
  end

  defp handle_result({:ok, {item, {:error, reason}}}, run_id) do
    {:ok, _} = Items.record_failed(item, format_error(reason))
    ProgressServer.record_failed(run_id)
  end

  defp handle_result({:exit, reason}, _run_id) do
    # Task killed (e.g. the 6h timeout). The item stays pending and is
    # retried on the next run; nothing to record here.
    Logger.warning("archive upload task exited: #{inspect(reason)}")
  end

  defp upload_item(driver, run, item) do
    full_path = Path.join(run.source_path, item.relative_path)
    driver.put_stream(run.destination, item.object_key, full_path, [])
  rescue
    error -> {:error, error}
  catch
    kind, value -> {:error, {kind, value}}
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)
end
