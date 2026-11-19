# ![# secant-service](https://github.com/Bilchreis/secant-service/blob/main/priv/static/images/secant-service.svg)

To start your Phoenix server:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Database

Parameter values are stored in [TimescaleDB](https://docs.tigerdata.com/)
hypertables with compression, so Postgres needs the `timescaledb` extension
installed and preloaded (`shared_preload_libraries = 'timescaledb'`). The
migrations fail on a plain Postgres.

The easiest way to get one for development is the image in `docker/postgres`
(Postgres 17 + TimescaleDB, telemetry off):

    docker build -t secant-postgres docker/postgres
    docker run -d --name secant-postgres -e POSTGRES_PASSWORD=postgres \
      -p 127.0.0.1:5434:5432 secant-postgres

    export PGPORT=5434   # dev and test read the port from PGPORT (default 5432)
    mix setup

`docker compose up -d --build db` builds the same image for the production
setup in `docker-compose.yml`.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

  * Official website: https://www.phoenixframework.org/
  * Guides: https://hexdocs.pm/phoenix/overview.html
  * Docs: https://hexdocs.pm/phoenix
  * Forum: https://elixirforum.com/c/phoenix-forum
  * Source: https://github.com/phoenixframework/phoenix
