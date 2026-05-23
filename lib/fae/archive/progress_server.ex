defmodule Fae.Archive.ProgressServer do
  @moduledoc """
  Holds live, in-flight progress for active archive runs and pushes
  throttled snapshots onto the `archive:progress` topic on a timer.

  Per the desktop-app state-ownership decision, in-flight progress lives
  here (a supervised process), not in the database — the DB carries only
  the durable per-item records and the final tally. The server keeps one
  message per run; reads (`snapshot/1`) and writes (`record_*`) are low
  frequency (bounded by upload concurrency), so the single process is not
  a throughput concern.
  """
  use GenServer

  alias Fae.Topics

  @default_interval_ms 500

  @type snapshot :: %{
          run_id: Ecto.UUID.t(),
          total_files: non_neg_integer(),
          total_bytes: non_neg_integer(),
          uploaded_files: non_neg_integer(),
          uploaded_bytes: non_neg_integer(),
          failed_files: non_neg_integer(),
          elapsed_ms: non_neg_integer()
        }

  # ── Client ────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Begins tracking a run. On resume, pass the already-completed tallies
  in `seed` (`:uploaded_files`, `:uploaded_bytes`, `:failed_files`) so
  the live view reflects total progress, not just this session's.
  """
  @spec start_run(Ecto.UUID.t(), non_neg_integer(), non_neg_integer(), map()) :: :ok
  def start_run(run_id, total_files, total_bytes, seed \\ %{}) do
    GenServer.cast(__MODULE__, {:start_run, run_id, total_files, total_bytes, seed})
  end

  @spec record_uploaded(Ecto.UUID.t(), non_neg_integer()) :: :ok
  def record_uploaded(run_id, bytes) do
    GenServer.cast(__MODULE__, {:record, run_id, :uploaded, bytes})
  end

  @spec record_failed(Ecto.UUID.t()) :: :ok
  def record_failed(run_id) do
    GenServer.cast(__MODULE__, {:record, run_id, :failed, 0})
  end

  @doc "Current snapshot for a run, or nil if it isn't being tracked."
  @spec snapshot(Ecto.UUID.t()) :: snapshot() | nil
  def snapshot(run_id), do: GenServer.call(__MODULE__, {:snapshot, run_id})

  @doc "Pushes a final snapshot and stops tracking the run."
  @spec finish_run(Ecto.UUID.t()) :: :ok
  def finish_run(run_id), do: GenServer.cast(__MODULE__, {:finish_run, run_id})

  # ── Server ────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    interval =
      Keyword.get(
        opts,
        :interval_ms,
        Application.get_env(:fae, :archive_progress_interval_ms, @default_interval_ms)
      )

    schedule_tick(interval)
    {:ok, %{runs: %{}, interval_ms: interval}}
  end

  @impl true
  def handle_cast({:start_run, run_id, total_files, total_bytes, seed}, state) do
    entry = %{
      run_id: run_id,
      total_files: total_files,
      total_bytes: total_bytes,
      uploaded_files: Map.get(seed, :uploaded_files, 0),
      uploaded_bytes: Map.get(seed, :uploaded_bytes, 0),
      failed_files: Map.get(seed, :failed_files, 0),
      started_monotonic_ms: System.monotonic_time(:millisecond)
    }

    {:noreply, put_in(state.runs[run_id], entry)}
  end

  def handle_cast({:record, run_id, kind, bytes}, state) do
    case state.runs do
      %{^run_id => entry} ->
        {:noreply, put_in(state.runs[run_id], apply_record(entry, kind, bytes))}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:finish_run, run_id}, state) do
    case state.runs do
      %{^run_id => entry} ->
        broadcast(entry)
        {:noreply, %{state | runs: Map.delete(state.runs, run_id)}}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:snapshot, run_id}, _from, state) do
    reply =
      case state.runs do
        %{^run_id => entry} -> to_snapshot(entry)
        _ -> nil
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    Enum.each(state.runs, fn {_run_id, entry} -> broadcast(entry) end)
    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  defp apply_record(entry, :uploaded, bytes) do
    %{
      entry
      | uploaded_files: entry.uploaded_files + 1,
        uploaded_bytes: entry.uploaded_bytes + bytes
    }
  end

  defp apply_record(entry, :failed, _bytes) do
    %{entry | failed_files: entry.failed_files + 1}
  end

  defp to_snapshot(entry) do
    elapsed_ms = System.monotonic_time(:millisecond) - entry.started_monotonic_ms

    entry
    |> Map.drop([:started_monotonic_ms])
    |> Map.put(:elapsed_ms, elapsed_ms)
  end

  defp broadcast(entry) do
    snapshot = to_snapshot(entry)

    Phoenix.PubSub.broadcast(
      Fae.PubSub,
      Topics.archive_progress(),
      {:archive_progress, entry.run_id, snapshot}
    )
  end

  defp schedule_tick(interval_ms), do: Process.send_after(self(), :tick, interval_ms)
end
