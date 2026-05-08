#!/usr/bin/env bash
# =============================================================================
# migrate-add-ns4.sh - Migration: (legacy) extend an ns1/ns2/ns3 .env for ns4
#
# - adds NS4_* variables, Patroni policy for NS4 and ETCD_INITIAL_CLUSTER
# - maps site label CA -> DE (node-init.sh now handles this automatically)
# - keeps secrets unchanged
#
# Usage (run on EACH existing host):
#   sudo -iu dockeruseragent
#   cd ~/dnscluster
#   ./scripts/migrate-add-ns4.sh
#
# Afterward: run ./scripts/node-init.sh <ns1|ns2|ns3> again to refresh the
# computed section (NODE_SITE etc.).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

. "$(dirname "$0")/env-load.sh"

ENV_FILE=".env"
[ -f "$ENV_FILE" ] || { echo "Missing: $ENV_FILE" >&2; exit 1; }

if grep -q '^CLUSTER_NODES=' "$ENV_FILE"; then
  echo "This repo now uses CLUSTER_NODES + NODE_<NODE>_* (new schema)." >&2
  echo "migrate-add-ns4.sh is legacy and no longer needed." >&2
  exit 1
fi

ts="$(date +%Y%m%d-%H%M%S)"
cp -a "$ENV_FILE" "${ENV_FILE}.bak.${ts}"

load_env "$ENV_FILE"

node="${NODE_NAME:-}"
if [ -z "$node" ]; then
  # Fallback: versuche NODE_NAME= aus Datei
  node="$(awk -F= '/^NODE_NAME=/{print $2; exit}' "$ENV_FILE" | tr -d '\r')"
fi
case "$node" in
  ns1|ns2|ns3) : ;;
  *) echo "Could not determine NODE_NAME (expected ns1/ns2/ns3). Run node-init.sh first." >&2; exit 1 ;;
esac

ensure_kv() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    return 0
  fi
  echo "${key}=${value}" >>"$ENV_FILE"
}

echo "==> Add CLUSTER_BRIDGE_SUBNET for Patroni pg_hba (if missing)"
ensure_kv "CLUSTER_BRIDGE_SUBNET" "172.28.0.0/24"

echo "==> Add NS4_* defaults to $ENV_FILE (if missing)"
ensure_kv "NS4_PUBLIC_IPV4" ""
ensure_kv "NS4_PUBLIC_IPV6" ""
ensure_kv "NS4_WG_IP" "10.100.0.4"
ensure_kv "NS4_WG_AF" "auto"

echo "==> Add Patroni policy for NS4 (if missing)"
ensure_kv "PATRONI_FAILOVER_PRIORITY_NS4" "25"
ensure_kv "PATRONI_NOFAILOVER_NS4" "false"

echo "==> Add ns4 to ETCD_INITIAL_CLUSTER (if present)"
if grep -qE '^ETCD_INITIAL_CLUSTER=' "$ENV_FILE"; then
  cur="$(awk -F= '/^ETCD_INITIAL_CLUSTER=/{sub(/^ETCD_INITIAL_CLUSTER=/,""); print; exit}' "$ENV_FILE" | tr -d '\r')"
  if [[ "$cur" != *"ns4="* ]]; then
    # best-effort: append ns4
    new="${cur},ns4=http://10.100.0.4:2380"
    # in-place replace (first occurrence) without a perl dependency
    tmp="$(mktemp)"
    awk -v repl="ETCD_INITIAL_CLUSTER=${new}" '
      BEGIN{done=0}
      /^ETCD_INITIAL_CLUSTER=/{ if(done==0){print repl; done=1; next} }
      {print}
    ' "$ENV_FILE" >"$tmp"
    mv "$tmp" "$ENV_FILE"
  fi
else
  ensure_kv "ETCD_INITIAL_CLUSTER" "ns1=http://10.100.0.1:2380,ns2=http://10.100.0.2:2380,ns3=http://10.100.0.3:2380,ns4=http://10.100.0.4:2380"
fi

echo "==> Done. Backup: ${ENV_FILE}.bak.${ts}"
echo "    Next step on this host:"
echo "      ./scripts/node-init.sh ${node}"
