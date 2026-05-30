import Config

# Disable auto-tick on the application-level SystemStatus during tests.
# Tests that need ticks instantiate their own SystemStatus with an explicit
# `tick_interval_ms` (or call `tick/1` manually).
config :fae, Fae.SystemStatus, tick_interval_ms: :infinity

# Oban runs jobs synchronously in tests so suites don't depend on the
# job queue's worker pool or cron schedule firing at real wall-clock time.
config :fae, Oban, testing: :inline

# Point Dotfiles at a per-run temp tree so tests never touch the real $HOME.
config :fae, Fae.Dotfiles,
  git_dir: Path.join(System.tmp_dir!(), "fae-dotfiles-test/repo.git"),
  work_tree: Path.join(System.tmp_dir!(), "fae-dotfiles-test/home")

# Don't re-enqueue resumable archive runs at app boot during tests — the
# boot hook would query the Repo before the per-test sandbox is set up.
# Tests drive the worker directly.
config :fae, Fae.Archive, resume_on_boot: false

# Short progress-broadcast interval so progress assertions don't wait
# half a second per check.
config :fae, :archive_progress_interval_ms, 25

# Disable the application-level Backups.Scheduler in tests so its
# global GenServer doesn't fight with per-test SQL sandboxes. Tests
# that need scheduling logic start a Scheduler manually inside the
# test's sandbox.
config :fae, Fae.Backups.Scheduler, enabled: false

# Same for the Notifier — disabled by default in test; specific tests
# start one manually with a stub notify_runner.
config :fae, Fae.Backups.Notifier, enabled: false

# Same for the SuspendWatcher — its periodic ticks would compete with
# the per-test sandbox. Tests that exercise it start one manually with
# an injected on_resume callback.
config :fae, Fae.Backups.SuspendWatcher, enabled: false

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
