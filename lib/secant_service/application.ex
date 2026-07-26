defmodule SecantService.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SecantServiceWeb.Telemetry,
      SecantService.Repo,
      {DNSCluster, query: Application.get_env(:secant_service, :dns_cluster_query) || :ignore},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:secant_service, :ash_domains),
         Application.fetch_env!(:secant_service, Oban)
       )},
      SecantService.StartupTriggerRunner,
      # Start the Finch HTTP client for sending emails
      {Phoenix.PubSub, name: SecantService.PubSub},
      {Finch, name: SecantService.Finch},
      {Registry, keys: :unique, name: Registry.NodeDBWriter},
      {Registry, keys: :unique, name: Registry.NodeValues},
      {Registry, keys: :unique, name: Registry.NodeServices},
      {Registry, keys: :unique, name: Registry.PlotCacheSupervisor},
      {Registry, keys: :unique, name: Registry.PlotCacheDispatcher},
      {Registry, keys: :unique, name: Registry.PlotCache},
      SecantClient.Supervisor,
      SecantService.NodeManager,
      {SecantService.NodeSupervisor, []},
      # Start a worker by calling: SecantService.Worker.start_link(arg)
      # {SecantService.Worker, arg},
      # Start to serve requests, typically the last entry
      SecantServiceWeb.Endpoint,
      {AshAuthentication.Supervisor, [otp_app: :secant_service]}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SecantService.Supervisor]
    result = Supervisor.start_link(children, opts)

    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SecantServiceWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
