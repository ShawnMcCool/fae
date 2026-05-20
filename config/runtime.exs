import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere.

# Releases need explicit opt-in to start the HTTP server.
if System.get_env("PHX_SERVER") do
  config :fae, FaeWeb.Endpoint, server: true
end

if config_env() == :prod do
  # XDG-compliant data directory: $XDG_DATA_HOME/fae or $HOME/.local/share/fae
  data_home =
    System.get_env("XDG_DATA_HOME") ||
      Path.join(System.fetch_env!("HOME"), ".local/share")

  fae_data_dir = Path.join(data_home, "fae")
  File.mkdir_p!(fae_data_dir)

  database_path = System.get_env("DATABASE_PATH") || Path.join(fae_data_dir, "fae.db")

  # Auto-generated and persisted on first run. This is a desktop app — the
  # user should not have to manage application secrets manually. The key
  # file is mode 0600; same threat model as ~/.ssh/id_*.
  secret_key_path = Path.join(fae_data_dir, "secret_key_base")

  secret_key_base =
    case File.read(secret_key_path) do
      {:ok, key} ->
        String.trim(key)

      _ ->
        key = :crypto.strong_rand_bytes(48) |> Base.encode64() |> String.trim()
        File.write!(secret_key_path, key)
        File.chmod!(secret_key_path, 0o600)
        key
    end

  port = String.to_integer(System.get_env("PORT", "4321"))

  config :fae, Fae.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # CRITICAL — load-bearing for the trust model. Fae has no application-layer
  # authentication (see docs/decisions/architecture/
  # 2026-05-16-028-no-application-layer-auth-on-single-user-desktop.md). The
  # entire security posture rests on this binding being 127.0.0.1 only. Do
  # NOT change to {0, 0, 0, 0} or {0, 0, 0, 0, 0, 0, 0, 0} without revisiting
  # that decision and implementing app-layer auth.
  config :fae, FaeWeb.Endpoint,
    url: [host: "127.0.0.1", port: port, scheme: "http"],
    http: [ip: {127, 0, 0, 1}, port: port],
    check_origin: ["//127.0.0.1:#{port}", "//localhost:#{port}"],
    secret_key_base: secret_key_base
end
