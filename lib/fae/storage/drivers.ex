defmodule Fae.Storage.Drivers do
  @moduledoc """
  Dispatch from a `Fae.Storage.Destination` to a concrete driver
  module. Tests can override the mapping by configuring
  `:storage_drivers` on `:fae` — e.g.,

      Application.put_env(:fae, :storage_drivers, %{"s3" => Fae.Storage.Drivers.DriverMock})
  """

  alias Fae.Storage.Destination

  @defaults %{"s3" => Fae.Storage.Drivers.S3}

  @spec driver_for(Destination.t()) :: module()
  def driver_for(%Destination{driver: name}) do
    Application.get_env(:fae, :storage_drivers, %{})
    |> Map.get(name, Map.fetch!(@defaults, name))
  end
end
