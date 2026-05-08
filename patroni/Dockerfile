# Patroni with Postgres 16. An official Patroni image exists, but is sometimes
# outdated; we build a slim image ourselves.
FROM postgres:16-bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv \
        gettext-base curl ca-certificates \
        postgresql-16-pgaudit \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/patroni-venv \
    && /opt/patroni-venv/bin/pip install --no-cache-dir \
        'patroni[etcd3]==4.0.4' \
        psycopg2-binary

ENV PATH="/opt/patroni-venv/bin:${PATH}"

# Postgres data (image layer; the real volume overrides it at runtime)
RUN mkdir -p /var/lib/postgresql/data/pgdata \
    && chown -R postgres:postgres /var/lib/postgresql

# Entrypoint runs as root: chown/chmod the volume, then run as postgres (PG16 permissions).
WORKDIR /home/postgres
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
CMD ["patroni", "/var/lib/postgresql/patroni.yml"]
