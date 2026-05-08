#!/bin/bash
set -euo pipefail

# As root: write config + fix PG16 data dir permissions (0700/0750) and owner postgres.
# Named volumes / rsync often produce root:root or overly permissive modes -> Postgres won't start.

CFG=/var/lib/postgresql/patroni.yml
mkdir -p /var/lib/postgresql
envsubst < /etc/patroni/patroni.yml.tpl > "$CFG"
chown postgres:postgres "$CFG"

DATA=/var/lib/postgresql/data
PGDATA="$DATA/pgdata"

if [[ -d "$PGDATA" ]]; then
  pguid="$(id -u postgres)"
  uid="$(stat -c '%u' "$PGDATA")"
  if [[ "$uid" != "$pguid" ]]; then
    chown -R postgres:postgres "$DATA"
  fi
  chmod 0700 "$PGDATA"
fi

exec runuser -u postgres -- "$@"
