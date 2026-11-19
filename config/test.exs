import Config
config :secant_service, Oban, testing: :manual
config :secant_service, token_signing_secret: "aAAT96csYVHMuEPfYDoDI3pDRgj7THhG"
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :secant_service, SecantService.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  # PGPORT lets you point at a TimescaleDB server on another port
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: "secant_service_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :secant_service, SecantServiceWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "ifnc2osJzplwUj7akmZBq522GurBJer7DXPeyAVt2Ks8MD6dxsmP6vjcip0//TIa",
  server: false

# In test we don't send emails
config :secant_service, SecantService.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
