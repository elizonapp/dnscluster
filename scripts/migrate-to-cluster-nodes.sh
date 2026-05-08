#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

. ./scripts/env-load.sh

if [ ! -f .env ]; then
  echo "Missing: .env" >&2
  exit 1
fi

load_env .env

if [ -n "${CLUSTER_NODES:-}" ]; then
  echo "CLUSTER_NODES is already set (${CLUSTER_NODES}) — aborting (looks like the new schema is already in use)." >&2
  exit 1
fi

set_env_value() {
  local key="$1" val="$2"
  if grep -q "^${key}=" .env; then
    local esc
    esc=$(printf '%s\n' "$val" | sed -e 's/[\/&|]/\\&/g')
    sed -i "s|^${key}=.*|${key}=${esc}|" .env
  else
    echo "${key}=${val}" >> .env
  fi
}

upper() { echo "$1" | tr '[:lower:]' '[:upper:]'; }

# Default legacy nodes: ns1..ns4
nodes="ns1,ns2,ns3,ns4"
set_env_value "CLUSTER_NODES" "$nodes"

for n in ns1 ns2 ns3 ns4; do
  up="$(upper "$n")"

  # Move WG mappings
  old_ip_var="${up}_WG_IP"
  old_af_var="${up}_WG_AF"
  old_v4_var="${up}_PUBLIC_IPV4"
  old_v6_var="${up}_PUBLIC_IPV6"

  ip="${!old_ip_var:-}"
  af="${!old_af_var:-}"
  v4="${!old_v4_var:-}"
  v6="${!old_v6_var:-}"

  [ -n "$ip" ] && set_env_value "NODE_${up}_WG_IP" "$ip"
  [ -n "$af" ] && set_env_value "NODE_${up}_WG_AF" "$af"
  [ -n "$v4" ] && set_env_value "NODE_${up}_PUBLIC_IPV4" "$v4"
  [ -n "$v6" ] && set_env_value "NODE_${up}_PUBLIC_IPV6" "$v6"
done

# ns3 policy per target design
set_env_value "PATRONI_FAILOVER_PRIORITY_NS3" "30"
set_env_value "PATRONI_NOFAILOVER_NS3" "false"

echo "==> Migration written. Now regenerate the computed section for this host:"
echo "    ./scripts/node-init.sh ${NODE_NAME:-<your-node>}"

