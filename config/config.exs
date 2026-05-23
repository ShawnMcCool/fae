# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :fae,
  ecto_repos: [Fae.Repo],
  generators: [timestamp_type: :utc_datetime]

# Captures the build-time env so runtime code can branch on it without
# leaking Mix into runtime. `Fae.SelfUpdate.enabled?/0` reads this.
config :fae, :environment, config_env()

# Oban with the SQLite-native Lite engine. The self_update queue is
# concurrency 1 — only one update can be in flight at a time (it writes
# to the install dir on disk).
#
# Cron schedule: minute :17 every six hours. The off-the-hour minute
# spreads installs across the 60s window so we stay comfortably under
# GitHub's 60/h unauthenticated rate limit.
config :fae, Oban,
  engine: Oban.Engines.Lite,
  repo: Fae.Repo,
  queues: [self_update: 1, backups: 1, archive: 1],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"17 */6 * * *", Fae.SelfUpdate.CheckerJob}
     ]}
  ]

# Tzdata-backed time zone database so DateTime calculations across DST
# boundaries are correct. Backup schedules resolve in a configured local
# zone via this database.
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

# Default local zone used to resolve backup schedules. Override per env
# in runtime.exs if needed.
config :fae, :timezone, "Etc/UTC"

# Configure the endpoint
config :fae, FaeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FaeWeb.ErrorHTML, json: FaeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Fae.PubSub,
  live_view: [signing_salt: "+5u2JUpP"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  fae: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  fae: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
