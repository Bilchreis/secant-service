# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ash_oban, pro?: false

config :secant_service, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  plugins: [{Oban.Plugins.Cron, []}],
  queues: [
    default: 10,
    sec_node_cleanup_old_nodes: 10,
    sec_node_purge_trashed_nodes: 10,
    sec_node_recalculate_storage_active: 10,
    sec_node_recalculate_storage_on_archive: 10,
    sec_node_sync_node_states: 10
  ],
  repo: SecantService.Repo

config :mime,
  extensions: %{"json" => "application/vnd.api+json"},
  types: %{"application/vnd.api+json" => ["json"]}

config :ash_json_api,
  show_public_calculations_when_loaded?: false,
  authorize_update_destroy_with_error?: true

config :ash,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :admin,
        :authentication,
        :token,
        :user_identity,
        :postgres,
        :json_api,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [
        :admin,
        :json_api,
        :resources,
        :policies,
        :authorization,
        :domain,
        :execution
      ]
    ]
  ]

config :secant_service,
  ecto_repos: [SecantService.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [SecantService.SecNodes, SecantService.Accounts]

# Configures the endpoint
config :secant_service, SecantServiceWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SecantServiceWeb.ErrorHTML, json: SecantServiceWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SecantService.PubSub,
  live_view: [signing_salt: "JEmZCdo/"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :secant_service, SecantService.Mailer, adapter: Swoosh.Adapters.Local

# Time-range buttons offered on live/historical plots, and which one is
# selected by default for :live plots (index into range_buttons).
config :secant_service, :plot_db,
  range_buttons: [
    %{label: "1m", step: "minute", count: 1},
    %{label: "10m", step: "minute", count: 10},
    %{label: "30m", step: "minute", count: 30},
    %{label: "1h", step: "hour", count: 1},
    %{label: "1d", step: "day", count: 1},
    %{label: "all", step: "all"}
  ],
  default_active_range_index: 1

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.5",
  secant_service: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  secant_service: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

config :pythonx, :uv_init,
  pyproject_toml: """
  [project]
  name = "secop_checker"
  version = "0.0.1"
  requires-python = "==3.13.*"
  dependencies = [
    "secop_check @ git+https://github.com/Bilchreis/secop_check.git",
    "secop-ophyd"
  ]
  """

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
