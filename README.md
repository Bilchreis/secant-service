# ![# secant-service](https://github.com/Bilchreis/secant-service/blob/main/priv/static/images/secant-service.svg)

To start your Phoenix server:

  * Start the development database with `docker compose -f compose.dev.yml up -d`
  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Database

Parameter values are stored in [TimescaleDB](https://docs.tigerdata.com/)
hypertables with compression, so Postgres needs the `timescaledb` extension
installed and preloaded (`shared_preload_libraries = 'timescaledb'`). The
migrations fail on a plain Postgres.

`compose.dev.yml` runs one for development: the image in `docker/postgres`
(Postgres 17 + TimescaleDB, telemetry off) on `127.0.0.1:5435`, which is where
`config/dev.exs` and `config/test.exs` connect by default. It restarts with
Docker and keeps its data in the `secant-pgdata` volume. It is a separate
compose project from `docker-compose.yml`, so the two never share containers
or data.

To use your own Postgres with TimescaleDB instead, set `PGPORT` to its port
(e.g. `export PGPORT=5432`).

`docker compose up -d --build db` builds the same image for the production
setup in `docker-compose.yml`.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

  * Official website: https://www.phoenixframework.org/
  * Guides: https://hexdocs.pm/phoenix/overview.html
  * Docs: https://hexdocs.pm/phoenix
  * Forum: https://elixirforum.com/c/phoenix-forum
  * Source: https://github.com/phoenixframework/phoenix
