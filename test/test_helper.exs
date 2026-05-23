# `:integration` tests hit a real S3-compatible endpoint (local MinIO)
# and are excluded from the default hermetic run. Run them with:
#   mix test --include integration
ExUnit.start(exclude: [:integration])
Ecto.Adapters.SQL.Sandbox.mode(Fae.Repo, :manual)

Mox.defmock(Fae.Storage.Drivers.DriverMock, for: Fae.Storage.Drivers.Driver)
