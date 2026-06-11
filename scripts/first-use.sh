#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage:
  ./scripts/first-use.sh init [--domain <domain>] [--nodes <ns1,ns2,...>] [--acme-email <email>]
                          [--wg-subnet <cidr>] [--wg-ip <node=ip> ...] [--wg-af <node=auto|v4|v6> ...]
                          [--site <node=label> ...] [--generate-secrets]

  sudo ./scripts/first-use.sh apply --node <node> [--with-firewall] [--skip-docker]

Notes:
  - init creates/patches .env idempotently (cluster-wide identical; NODE_NAME stays per host).
  - apply delegates to scripts/install.sh (host provisioning), including:
      /etc/systemd/resolved.conf → DNSStubListener=no (if [Resolve] exists)
      so WireGuard FQDN lookups use public DNS instead of the 127.0.0.53 stub.
EOF
}

set_env_value() {
  local key="$1" val="$2"
  if grep -q "^${key}=" .env 2>/dev/null; then
    local esc
    esc=$(printf '%s\n' "$val" | sed -e 's/[\/&|]/\\&/g')
    sed -i "s|^${key}=.*|${key}=${esc}|" .env
  else
    echo "${key}=${val}" >> .env
  fi
}

upper() { echo "$1" | tr '[:lower:]' '[:upper:]'; }

ensure_env() {
  if [ ! -f .env ]; then
    cp .env.example .env
  fi
}

gen_etcd_initial_cluster() {
  local nodes_csv="$1"
  local out="" first=1
  IFS=',' read -r -a nodes <<<"$nodes_csv"
  for n in "${nodes[@]}"; do
    n="${n## }"; n="${n%% }"
    [ -z "$n" ] && continue
    local up ip_var ip
    up="$(upper "$n")"
    ip_var="NODE_${up}_WG_IP"
    ip="${!ip_var:-}"
    [ -z "$ip" ] && continue
    if [ "$first" -eq 1 ]; then first=0; else out="${out},"; fi
    out="${out}${n}=http://${ip}:2380"
  done
  echo "$out"
}

cmd_init() {
  local domain="" nodes="ns1,ns2,ns3,ns4" acme_email="" wg_subnet="" generate_secrets=0
  declare -a wg_ips=() wg_afs=() sites=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --domain) domain="$2"; shift 2 ;;
      --nodes) nodes="$2"; shift 2 ;;
      --acme-email) acme_email="$2"; shift 2 ;;
      --wg-subnet) wg_subnet="$2"; shift 2 ;;
      --wg-ip) wg_ips+=("$2"); shift 2 ;;
      --wg-af) wg_afs+=("$2"); shift 2 ;;
      --site) sites+=("$2"); shift 2 ;;
      --generate-secrets) generate_secrets=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
  done

  ensure_env

  [ -n "$domain" ] && set_env_value "NODE_FQDN_DOMAIN" "$domain"
  [ -n "$acme_email" ] && set_env_value "ACME_EMAIL" "$acme_email"
  [ -n "$wg_subnet" ] && set_env_value "WG_SUBNET" "$wg_subnet"

  set_env_value "CLUSTER_NODES" "$nodes"

  # Apply mappings
  local kv node ip up
  for kv in "${wg_ips[@]}"; do
    node="${kv%%=*}"; ip="${kv#*=}"
    up="$(upper "$node")"
    set_env_value "NODE_${up}_WG_IP" "$ip"
  done
  for kv in "${wg_afs[@]}"; do
    node="${kv%%=*}"; ip="${kv#*=}"
    up="$(upper "$node")"
    set_env_value "NODE_${up}_WG_AF" "$ip"
  done
  for kv in "${sites[@]}"; do
    node="${kv%%=*}"; ip="${kv#*=}"
    up="$(upper "$node")"
    set_env_value "NODE_${up}_SITE" "$ip"
  done

  # etcd initial cluster best-effort (bootstrap)
  . ./scripts/env-load.sh
  load_env .env
  etcd_cluster="$(gen_etcd_initial_cluster "$CLUSTER_NODES")"
  [ -n "$etcd_cluster" ] && set_env_value "ETCD_INITIAL_CLUSTER" "$etcd_cluster"

  # Ensure ns3 policy defaults for new installs if missing
  if ! grep -q '^PATRONI_FAILOVER_PRIORITY_NS3=' .env; then
    echo "PATRONI_FAILOVER_PRIORITY_NS3=30" >> .env
  fi
  if ! grep -q '^PATRONI_NOFAILOVER_NS3=' .env; then
    echo "PATRONI_NOFAILOVER_NS3=false" >> .env
  fi

  if [ "$generate_secrets" -eq 1 ]; then
    ./scripts/bootstrap.sh
  fi

  echo "==> init complete. Next step on each host:"
  echo "    sudo ./scripts/first-use.sh apply --node <node>"
}

cmd_apply() {
  local node="" passthru=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --node) node="$2"; shift 2 ;;
      --with-firewall|--skip-docker) passthru+=("$1"); shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
  done
  [ -n "$node" ] || { echo "--node is required" >&2; exit 1; }
  exec ./scripts/install.sh --node "$node" "${passthru[@]}"
}

case "${1:-}" in
  init) shift; cmd_init "$@" ;;
  apply) shift; cmd_apply "$@" ;;
  -h|--help|"") usage; exit 0 ;;
  *) echo "Unknown command: $1" >&2; usage; exit 1 ;;
esac

