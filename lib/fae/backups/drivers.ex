defmodule Fae.Backups.Drivers do
  @moduledoc """
  Dispatch from a `Fae.Backups.Destination` to a concrete driver
  module. Tests can override the mapping by configuring
  `:backups_drivers` on `:fae` — e.g.,

      Application.put_env(:fae, :backups_drivers, %{"s3" => Fae.Backups.Drivers.DriverMock})
  """

  alias Fae.Backups.Destination

  @defaults %{"s3" => Fae.Backups.Drivers.S3}

  @spec driver_for(Destination.t()) :: module()
  def driver_for(%Destination{driver: name}) do
    Application.get_env(:fae, :backups_drivers, %{})
    |> Map.get(name, Map.fetch!(@defaults, name))
  end
end
