#!/usr/bin/env bash
# =============================================================================
# cluster-sync.sh - Inter-node operations via SSH
#
# Subcommands:
#   distribute-pubkey         Copy this node's WG public key to other nodes
#                             (stores it as wireguard/keys/publickey.<self>).
#                             Then triggers wireguard-render remotely.
#
#   pull-pubkeys              Fetch other nodes' WG public keys locally
#                             (stored as wireguard/keys/publickey.<peer>).
#
#   reresolve [target]        Trigger wg-reresolve.sh on <target> (or all peers).
#                             Useful after IP changes.
#
#   status                    Show 'wg show' and Patroni cluster status
#                             for all nodes.
#
#   update-public-ip <peer> <ipv4|ipv6> <value>
#                             Update NODE_<PEER>_PUBLIC_IPV{4,6} in .env on all
#                             nodes (informational; WG uses FQDN+DNS) and
#                             trigger reresolve.
#
# Communication: SSH as user SYNC_SSH_USER (default: ns-cluster-sync), port from
# SYNC_SSH_PORT. Identity: ~/.ssh/cluster_sync_ed25519 (created by install.sh).
# The sync account needs a login shell /bin/bash (nologin breaks remote commands).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

. "$(dirname "$0")/env-load.sh"
load_env .env
: "${NODE_NAME:?NODE_NAME must be set in .env (run node-init.sh first)}"
: "${NODE_FQDN_DOMAIN:?NODE_FQDN_DOMAIN missing in .env}"
: "${CLUSTER_NODES:?CLUSTER_NODES missing in .env}"

SSH_USER="${SYNC_SSH_USER:-ns-cluster-sync}"
SSH_PORT="${SYNC_SSH_PORT:-22}"
SSH_KEY="${HOME}/.ssh/cluster_sync_ed25519"
# ssh: Port mit -p; scp: Port mit -P (kleines -p bei scp = preserve, sonst "22" als Quellpfad)
SSH_COMMON_OPTS=(
    -i "$SSH_KEY"
    -o StrictHostKeyChecking=accept-new
    -o BatchMode=yes
    -o ConnectTimeout=10
)
SSH_OPTS=("${SSH_COMMON_OPTS[@]}" -p "$SSH_PORT")
SCP_OPTS=("${SSH_COMMON_OPTS[@]}" -P "$SSH_PORT")

REMOTE_STACK="/home/dockeruseragent/dnscluster"
REMOTE_SERVICE_USER="dockeruseragent"

other_nodes() {
    IFS=',' read -r -a _nodes <<<"$CLUSTER_NODES"
    for n in "${_nodes[@]}"; do
        n="${n## }"; n="${n%% }"
        [ -z "$n" ] && continue
        [ "$n" != "$NODE_NAME" ] && echo "$n"
    done
}

fqdn_for() { echo "${1}.${NODE_FQDN_DOMAIN}"; }

remote() {
    # $1 = peer, rest = command
    local peer="$1"; shift
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@$(fqdn_for "$peer")" "$@"
}

# Pubkey per SSH + sudo -u dockeruseragent (nicht scp): der Service-User darf immer in keys/ schreiben.
push_pubkey_ssh() {
    local peer="$1"
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@$(fqdn_for "$peer")" \
        "sudo -u ${REMOTE_SERVICE_USER} ${REMOTE_STACK}/scripts/sync-receive-pubkey.sh ${NODE_NAME}" \
        < wireguard/keys/publickey
}

# ---------------------------------------------------------------------------
cmd_distribute_pubkey() {
    [ -f wireguard/keys/publickey ] || { echo "missing: wireguard/keys/publickey"; exit 1; }
    for peer in $(other_nodes); do
        echo "==> Push public key to $peer"
        push_pubkey_ssh "$peer"
        # Exakter Pfad: sudoers matcht nur diesen Eintrag; Skript muss root sein (schreibt /etc/wireguard).
        remote "$peer" "sudo ${REMOTE_STACK}/scripts/wireguard-render.sh"
    done
    echo "==> Done."
}

cmd_pull_pubkeys() {
    for peer in $(other_nodes); do
        echo "==> Fetch public key from $peer"
        scp "${SCP_OPTS[@]}" \
            "${SSH_USER}@$(fqdn_for "$peer"):/home/dockeruseragent/dnscluster/wireguard/keys/publickey" \
            "wireguard/keys/publickey.${peer}"
    done
}

cmd_reresolve() {
    local target="${1:-all}"
    if [ "$target" = "all" ]; then
        # Lokal selbst auch
        sudo /usr/local/sbin/wg-reresolve.sh || true
        for peer in $(other_nodes); do
            echo "==> Trigger reresolve on $peer"
            remote "$peer" "sudo /usr/local/sbin/wg-reresolve.sh" || echo "    (failed)"
        done
    elif [ "$target" = "self" ] || [ "$target" = "$NODE_NAME" ]; then
        sudo /usr/local/sbin/wg-reresolve.sh
    else
        remote "$target" "sudo /usr/local/sbin/wg-reresolve.sh"
    fi
}

cmd_status() {
    echo "============== $NODE_NAME (lokal) =============="
    wg show wg0 2>/dev/null || echo "wg0 not active"
    echo
    curl -s --max-time 3 "http://${NODE_WG_IP}:8008/cluster" 2>/dev/null | jq . 2>/dev/null \
        || echo "Patroni API not reachable"

    for peer in $(other_nodes); do
        echo
        echo "============== $peer =============="
        remote "$peer" "wg show wg0" 2>/dev/null || echo "(SSH/wg failed)"
    done
}

cmd_update_public_ip() {
    local peer="$1" family="$2" value="$3"
    local prefix var_name
    prefix="$(echo "$peer" | tr '[:lower:]' '[:upper:]')"
    case "$family" in
        v4|ipv4) var_name="NODE_${prefix}_PUBLIC_IPV4" ;;
        v6|ipv6) var_name="NODE_${prefix}_PUBLIC_IPV6" ;;
        *) echo "family must be v4 or v6"; exit 1 ;;
    esac

    echo "==> Set ${var_name}=${value} locally in .env"
    if grep -q "^${var_name}=" .env; then
        sed -i "s|^${var_name}=.*|${var_name}=${value}|" .env
    else
        echo "${var_name}=${value}" >> .env
    fi

    for p in $(other_nodes); do
        echo "==> Distribute .env patch to $p"
        remote "$p" "cd /home/dockeruseragent/dnscluster && \
            if grep -q '^${var_name}=' .env; then \
                sed -i 's|^${var_name}=.*|${var_name}=${value}|' .env; \
            else \
                echo '${var_name}=${value}' >> .env; \
            fi"
    done

    # WG itself uses FQDNs; reresolve applies changes once DNS is updated
    echo "==> .env updated on all nodes. If DNS is already updated:"
    echo "    $0 reresolve all"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
    distribute-pubkey)  shift; cmd_distribute_pubkey ;;
    pull-pubkeys)       shift; cmd_pull_pubkeys ;;
    reresolve)          shift; cmd_reresolve "${1:-all}" ;;
    status)             shift; cmd_status ;;
    update-public-ip)
        shift
        [ $# -eq 3 ] || { echo "Usage: $0 update-public-ip <peer> <v4|v6> <value>"; exit 1; }
        cmd_update_public_ip "$1" "$2" "$3"
        ;;
    *)
        cat <<EOF
Usage: $0 <subcommand>

Subcommands:
  distribute-pubkey               Push this node's WG pubkey to all peers
  pull-pubkeys                    Fetch all peers' WG pubkeys
  reresolve [self|<peer>|all]     Trigger wg-reresolve
  status                          Cluster overview
  update-public-ip <peer> v4|v6 <value>
                                  Update informational public IP entry in .env
                                  on all nodes

Note: WireGuard uses FQDNs as endpoints. Real IP changes are picked up by the
reresolve timer (every 5 minutes) once DNS is updated. update-public-ip only
updates the informational .env variable.
EOF
        exit 1
        ;;
esac
