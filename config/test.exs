import Config

# Disable auto-tick on the application-level SystemStatus during tests.
# Tests that need ticks instantiate their own SystemStatus with an explicit
# `tick_interval_ms` (or call `tick/1` manually).
config :fae, Fae.SystemStatus, tick_interval_ms: :infinity

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :fae, Fae.Repo,
  database: Path.expand("../fae_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :fae, FaeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "ZPk4c1kruNAz6iP+driJ8d8rCKD1M/htWN2YCP7J+Bl/1/isZ1rmAffWg9DcgGh6",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
