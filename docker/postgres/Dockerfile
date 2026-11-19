# Postgres with the TimescaleDB extension.
#
# Built on the Debian bookworm postgres image the db service used before
# (postgres:17.4), so an existing data volume keeps its OS, glibc and
# collations. The official timescale/timescaledb images are Alpine-based
# (musl), whose text collation differs and would need a REINDEX of existing
# data. The TimescaleDB packages need Postgres >= 17.11; a minor upgrade within
# 17 uses the same on-disk format.
FROM postgres:17.12-bookworm

ARG TIMESCALEDB_VERSION=2.31.2

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
    curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey \
      | gpg --dearmor -o /usr/share/keyrings/timescaledb.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/timescaledb.gpg] https://packagecloud.io/timescale/timescaledb/debian/ bookworm main" \
      > /etc/apt/sources.list.d/timescaledb.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      "timescaledb-2-loader-postgresql-${PG_MAJOR}=${TIMESCALEDB_VERSION}~debian12*" \
      "timescaledb-2-${TIMESCALEDB_VERSION}-postgresql-${PG_MAJOR}"; \
    apt-get purge -y --auto-remove curl gnupg; \
    rm -rf /var/lib/apt/lists/*

# The extension must be preloaded. Passing it on the command line (rather than
# writing postgresql.conf in an init script) also covers data directories that
# were initialised before this image was used.
CMD ["postgres", "-c", "shared_preload_libraries=timescaledb", "-c", "timescaledb.telemetry_level=off"]
