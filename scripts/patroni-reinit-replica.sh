#!/usr/bin/env bash
# Reinitialize a replica if, for example:
#   "requested WAL segment ... has already been removed"
#
# IMPORTANT: Run only on a DNS cluster host whose Patroni container can reach
# the other etcd members via WireGuard IPs. Do NOT run from some random VPS
# without WireGuard access to 10.100.0.0/24, otherwise you'll get connect timeouts.
#
# Example:
#   cd ~/dnscluster && ./scripts/patroni-reinit-replica.sh ns1
#
# Requirement: Patroni on the target node must be healthy enough to pick up the
# reinit command from the DCS; otherwise consider clearing the data volume and
# restarting the stack (after backup/review).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/env-load.sh"
load_env "$ROOT/.env"

MEMBER="${1:-}"
if [[ -z "$MEMBER" ]]; then
  echo "Usage: $0 <member-name>" >&2
  echo "  member-name = NODE_NAME in Patroni, e.g. ns1" >&2
  exit 1
fi
if [[ -z "${CLUSTER_NODES:-}" ]]; then
  echo "CLUSTER_NODES missing in .env" >&2
  exit 1
fi

SELF_IP=""
if [[ -n "${NODE_NAME:-}" ]]; then
  self_prefix="$(echo "$NODE_NAME" | tr '[:lower:]' '[:upper:]')"
  self_ip_var="NODE_${self_prefix}_WG_IP"
  SELF_IP="${!self_ip_var:-}"
fi

echo "Checking etcd HTTP (via WG) from the Patroni container (no hairpin to own NODE_WG_IP) ..." >&2
ok=0
IFS=',' read -r -a _nodes <<<"$CLUSTER_NODES"
for n in "${_nodes[@]}"; do
  n="${n## }"; n="${n%% }"
  [[ -z "$n" ]] && continue
  prefix="$(echo "$n" | tr '[:lower:]' '[:upper:]')"
  ip_var="NODE_${prefix}_WG_IP"
  ip="${!ip_var:-}"
  [[ -z "$ip" ]] && continue
  [[ -n "$SELF_IP" && "$ip" == "$SELF_IP" ]] && continue
  if docker exec patroni curl -fsS --connect-timeout 3 "http://${ip}:2379/version" >/dev/null 2>&1; then
    ok=1
    echo "  OK: ${ip}:2379" >&2
  else
    echo "  failed: ${ip}:2379" >&2
  fi
done
if [[ "$ok" != 1 ]]; then
  echo "Abort: From this host, the Patroni container cannot reach any peer etcd via WireGuard IPs." >&2
  echo "Run this script on a cluster node with working WireGuard connectivity." >&2
  exit 1
fi

CLUSTER="$(docker exec patroni sh -c "grep -E '^scope:' /var/lib/postgresql/patroni.yml | awk '{print \$2}'")"
if [[ -z "$CLUSTER" ]]; then
  echo "Could not read scope from /var/lib/postgresql/patroni.yml inside the container." >&2
  exit 1
fi

echo "Reinit $MEMBER in scope $CLUSTER (container: patroni) ..."
docker exec patroni patronictl -c /var/lib/postgresql/patroni.yml reinit "$CLUSTER" "$MEMBER" --force

echo "Done. On $MEMBER if needed: docker compose restart patroni"
