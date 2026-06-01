import Config

config :phoenix, :json_library, Jason

database_name =
  System.get_env("HARMONY_DATABASE_NAME") ||
    if config_env() == :test, do: "harmony_test", else: "harmony_dev"

repo_config = [
  database: database_name,
  username: System.get_env("HARMONY_DATABASE_USER", "postgres"),
  password: System.get_env("HARMONY_DATABASE_PASSWORD", "postgres"),
  hostname: System.get_env("HARMONY_DATABASE_HOST", "localhost"),
  port: String.to_integer(System.get_env("HARMONY_DATABASE_PORT", "5432")),
  pool_size: String.to_integer(System.get_env("HARMONY_DATABASE_POOL_SIZE", "10"))
]

repo_config =
  if config_env() == :test do
    Keyword.put(repo_config, :pool, Ecto.Adapters.SQL.Sandbox)
  else
    repo_config
  end

config :symphony_elixir, ecto_repos: [SymphonyElixir.Repo]

config :symphony_elixir, SymphonyElixir.Repo, repo_config

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false
