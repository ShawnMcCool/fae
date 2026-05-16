defmodule Fae.Repo do
  use Ecto.Repo,
    otp_app: :fae,
    adapter: Ecto.Adapters.SQLite3
end
