ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Fae.Repo, :manual)

Mox.defmock(Fae.Backups.Drivers.DriverMock, for: Fae.Backups.Drivers.Driver)
