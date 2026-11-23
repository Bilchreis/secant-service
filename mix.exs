defmodule SecantService.MixProject do
  use Mix.Project

  # Bumping this is the release: once it lands on main, the release workflow
  # tests it, pushes the Docker image and creates the v<version> tag and
  # GitHub release.
  @version "0.5.1"

  def project do
    [
      app: :secant_service,
      version: @version,
      elixir: "~> 1.20.1",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: [
        # in _build, which CI caches with the rest of the build
        plt_core_path: "_build/#{Mix.env()}",
        plt_add_apps: [:mix, :ex_unit],
        flags: [:extra_return, :missing_return],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      consolidate_protocols: Mix.env() != :dev,
      usage_rules: usage_rules(),
      hex: [
        # assent 0.2.x: Sign in with Apple callback claims override
        # (GHSA-9fr5-g44g-9526). We only use the password and API key
        # strategies, so it doesn't apply. The fix is in assent 0.3+, but
        # ash_authentication 4.15 still requires < 0.3. Remove once it allows
        # the upgrade; `mix hex.audit --check-unused-ignores` flags it then.
        ignore_advisories: ["EEF-CVE-2026-117656"]
      ]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test, dialyzer: :test]]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {SecantService.Application, []},
      extra_applications: [:logger, :runtime_tools, :os_mon]
    ]
  end

  # Agent rules synced from deps by `mix usage_rules.sync` (part of
  # `mix precommit`). The packages are listed by name, not `:all`, so the
  # output doesn't change between dev and test, which have different deps.
  defp usage_rules do
    [
      # Short rules that apply to almost every change, inlined.
      file: "AGENTS.md",
      usage_rules: [
        # docs lookup tasks, plus its Elixir and OTP rules
        :usage_rules,
        "phoenix:elixir",
        "phoenix:phoenix",
        "phoenix:html",
        "phoenix:liveview"
      ],
      # Larger rule sets, loaded by the agent only when the task needs them.
      # The sync rewrites a SKILL.md only when its body changes, so after
      # editing just a description, delete that SKILL.md and sync again.
      skills: [
        location: ".claude/skills",
        build: [
          "use-sobelow": [
            description:
              "Sobelow security rules for Phoenix: XSS, SQL injection, unsafe atom/binary handling, CSRF and config findings. Load when handling user input in controllers, LiveViews or raw SQL, when `mix sobelow` reports a finding, or when editing .sobelow-skips.",
            usage_rules: [:sobelow]
          ],
          "ash-framework": [
            description:
              "Ash Framework rules: resources, actions, code interfaces, policies, relationships, calculations, AshPostgres migrations, AshPhoenix forms, AshOban triggers and AshAuthentication. Load before changing anything in lib/secant_service/ (domains and resources using Ash.Resource or Ash.Domain), running `mix ash.codegen`, or debugging Ash.Error.* errors.",
            usage_rules: [
              :ash,
              :ash_postgres,
              :ash_phoenix,
              :ash_oban,
              :ash_authentication
            ]
          ]
        ]
      ]
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
      {:ash_state_machine, "~> 0.2"},
      {:ash_admin, "~> 1.4"},
      {:ash_authentication_phoenix, "~> 2.0"},
      {:ash_authentication, "~> 4.0"},
      {:ash_postgres, "~> 2.0"},
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
      {:phoenix_live_dashboard, "~> 0.9.1"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.5"},
      {:finch, "~> 0.13"},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.3.1"},
      {:bandit, "~> 1.5"},
      {:secant_client, "~> 0.5.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.19", only: [:dev, :test], runtime: false},
      # test only, like precommit: a dev dependency would ask the running dev
      # server to recompile it
      {:dialyxir, "~> 1.4", only: :test, runtime: false},
      {:tzdata, "~> 1.1"},
      {:exprintf, "~> 0.2.1"},
      {:pythonx, "~> 0.4.4"},
      {:flame_on, git: "https://github.com/DockYard/flame_on.git", only: :dev},
      {:meck, "~> 1.0", override: true},
      {:benchee, "~> 1.5", only: :dev},
      # test too: `mix precommit` (test env) runs usage_rules.sync
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:usage_rules, "~> 1.3", only: [:dev, :test]}
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
      # Run before committing. CI runs the same checks in check-only mode.
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "usage_rules.sync --yes",
        "format",
        "credo --only warning --strict",
        "ash.codegen --check",
        "dialyzer",
        "test"
      ],
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
