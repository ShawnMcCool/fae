defmodule Fae.Clock do
  @moduledoc """
  Thin wrapper around `DateTime.utc_now/0` so tests can inject a
  frozen clock. Configure an alternate implementation via:

      config :fae, :clock, MyTestClock

  Implementations must implement the `now/0` callback returning a UTC
  `DateTime`.
  """

  @callback now() :: DateTime.t()

  @spec now() :: DateTime.t()
  def now, do: impl().now()

  defp impl, do: Application.get_env(:fae, :clock, __MODULE__.Default)

  defmodule Default do
    @moduledoc false
    @behaviour Fae.Clock

    @impl true
    def now, do: DateTime.utc_now()
  end
end
