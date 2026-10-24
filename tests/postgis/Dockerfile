# Test-only PostgreSQL with PostGIS; same major and base index as igilro-server.
FROM postgres:17.11-bookworm@sha256:3645570cccdfa447589da9f57dd740faa29b30938e861289a5574b6ca6b03826
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssl postgresql-17-postgis-3 postgresql-17-postgis-3-scripts \
    && rm -rf /var/lib/apt/lists/*
