defmodule Fae.SystemStatus do
  @moduledoc """
  Supervised heartbeat process that owns and broadcasts the application's
  live uptime state. Acts as the minimal demonstration of Fae's desktop-app
  pattern: state lives in the process, persists across observers, and
  reaches LiveViews via `Phoenix.PubSub` rather than database polling.
  """

  use GenServer

  @default_tick_interval_ms 1_000
  @topic "system_status"

  def start_link(opts \\ []) do
    {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
    start_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, start_opts)
  end

  def get_state(server \\ __MODULE__) do
    GenServer.call(server, :get_state)
  end

  @doc """
  Synchronously trigger one tick. Returns after the tick has been processed.
  Used both in tests (deterministic, no `Process.sleep`) and as a way to force
  an immediate update outside the normal cadence.
  """
  def tick(server \\ __MODULE__) do
    send(server, :tick)
    _ = :sys.get_state(server)
    :ok
  end

  @doc """
  Subscribe the calling process to status broadcasts. The caller receives
  `{:system_status, %{boot_at: DateTime.t(), uptime_seconds: non_neg_integer()}}`
  messages on every tick.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(Fae.PubSub, @topic)
  end

  @impl true
  def init(opts) do
    configured = Application.get_env(:fae, __MODULE__, [])

    tick_interval =
      Keyword.get(
        opts,
        :tick_interval_ms,
        Keyword.get(configured, :tick_interval_ms, @default_tick_interval_ms)
      )

    state = %{
      boot_at: DateTime.utc_now(),
      uptime_seconds: 0,
      tick_interval_ms: tick_interval
    }

    {:ok, state, {:continue, :schedule_first_tick}}
  end

  @impl true
  def handle_continue(:schedule_first_tick, state) do
    schedule_next_tick(state.tick_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, public_state(state), state}
  end

  @impl true
  def handle_info(:tick, state) do
    new_state = %{state | uptime_seconds: state.uptime_seconds + 1}
    Phoenix.PubSub.broadcast(Fae.PubSub, @topic, {:system_status, public_state(new_state)})
    schedule_next_tick(new_state.tick_interval_ms)
    {:noreply, new_state}
  end

  defp public_state(state), do: Map.take(state, [:boot_at, :uptime_seconds])

  defp schedule_next_tick(:infinity), do: :ok

  defp schedule_next_tick(ms) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :tick, ms)
  end
end
