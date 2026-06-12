defmodule SecantService.MixProject do
  use Mix.Project

  def project do
    [
      app: :secant_service,
      version: "0.0.15",
      elixir: "~> 1.20.1",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {SecantService.Application, []},
      extra_applications: [:logger, :wx, :runtime_tools, :observer, :os_mon, :secant_client]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:oban, "~> 2.0"},
      {:ash_oban, "~> 0.7"},
      {:picosat_elixir, "~> 0.2"},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:open_api_spex, "~> 3.0"},
      {:ash_state_machine, "~> 0.2"},
      {:ash_admin, "~> 0.13"},
      {:ash_authentication_phoenix, "~> 2.0"},
      {:ash_authentication, "~> 4.0"},
      {:ash_postgres, "~> 2.0"},
      {:ash_json_api, "~> 1.0"},
      {:ash_phoenix, "~> 2.0"},
      {:ash_pagify, "~> 1.4"},
      {:ash, "~> 3.0"},
      {:bcrypt_elixir, "~> 3.0"},
      {:phoenix, "~> 1.8"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_pubsub, "~> 2.0"},
      {:phoenix_live_view, "~> 1.1"},
      {:lazy_html, ">= 0.0.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.7"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.1.1",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.5"},
      {:finch, "~> 0.13"},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.20"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.1.1"},
      {:bandit, "~> 1.5"},
      {:secant_client, git: "https://github.com/Bilchreis/secant-client.git", tag: "v0.1.1"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:tzdata, "~> 1.1"},
      {:exprintf, "~> 0.2.1"},
      {:pythonx, "~> 0.4.4"},
      {:flame_on, git: "https://github.com/DockYard/flame_on.git", only: :dev},
      {:meck, "~> 1.0", override: true},
      {:benchee, "~> 1.5", only: :dev},
      {:igniter, "~> 0.6", only: :dev},
      {:usage_rules, "~> 0.1.26", only: :dev}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ash.setup", "assets.setup", "assets.build", "run priv/repo/seeds.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind secant_service", "esbuild secant_service"],
      "assets.deploy": [
        "tailwind secant_service --minify",
        "esbuild secant_service --minify",
        "phx.digest"
      ]
    ]
  end
end
