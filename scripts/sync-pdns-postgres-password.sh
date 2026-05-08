#!/usr/bin/env bash
# Set PostgreSQL role 'pdns' password to PDNS_DB_PASSWORD from .env.
# Must be run on the Patroni leader (ALTER ROLE is not allowed on replicas).
# If you're on a replica: run this script on the current leader node.
set -euo pipefail
cd "$(dirname "$0")/.."
. "$(dirname "$0")/env-load.sh"

[ -f .env ] || { echo "Missing: .env" >&2; exit 1; }
load_env .env
: "${PDNS_DB_PASSWORD:?PDNS_DB_PASSWORD not set}"

pw_esc=$(printf '%s' "$PDNS_DB_PASSWORD" | sed "s/'/''/g")

docker compose exec -T patroni bash -ec "
set -euo pipefail
if ! curl -sf -o /dev/null http://127.0.0.1:8008/primary; then
  echo 'This host is not the PostgreSQL leader (Patroni /primary != 200).' >&2
  echo 'Run this script on the leader node or retry after failover.' >&2
  exit 1
fi
psql -U postgres -h 127.0.0.1 -v ON_ERROR_STOP=1 -c \"ALTER ROLE pdns WITH PASSWORD '${pw_esc}';\"
"

echo "OK: Updated role 'pdns' on the primary (matches PDNS_DB_PASSWORD)."
