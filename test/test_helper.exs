# The end to end tests run a real SEC node with frappy. Without it they are
# skipped locally, but CI must not skip them silently.
exclude =
  cond do
    SecantService.FrappyServer.available?() ->
      []

    System.get_env("CI") ->
      raise "the :frappy end to end tests need frappy-server or uvx"

    true ->
      IO.puts("Skipping the :frappy end to end tests: neither frappy-server nor uvx found")
      [:frappy]
  end

ExUnit.start(exclude: exclude)

Ecto.Adapters.SQL.Sandbox.mode(SecantService.Repo, :manual)
