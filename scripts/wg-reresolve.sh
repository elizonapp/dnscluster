#!/usr/bin/env bash
# =============================================================================
# wg-reresolve.sh - Re-resolves peer endpoint FQDNs and updates wg0
#                   on IP changes.
#
# Called by a systemd timer every 5 minutes (see wg-reresolve.timer).
#
# Logic:
#   For each peer in /etc/wireguard/wg0.conf:
#     1. Endpoint-FQDN parsen
#     2. Resolve via DNS according to the address-family preference (v4|v6|auto)
#     3. Aktueller WG-Endpoint via 'wg show wg0 endpoints' holen
#     4. Bei Mismatch: 'wg set wg0 peer <pubkey> endpoint <new>'
#
# Address family:
#   .env contains NODE_<NODE>_WG_AF (auto|v4|v6).
#   "auto" = prefer AAAA, fallback to A.
#
# Idempotent: if DNS still returns the same IP, nothing changes.
# =============================================================================
set -euo pipefail

STACK_DIR="${STACK_DIR:-/home/dockeruseragent/dnscluster}"
LOG_TAG="wg-reresolve"

log() { logger -t "$LOG_TAG" -- "$*"; echo "[$(date -Iseconds)] $*"; }

if [ ! -f "$STACK_DIR/.env" ]; then
    log "ERROR: missing $STACK_DIR/.env"
    exit 1
fi

. "$STACK_DIR/scripts/env-load.sh"
load_env "$STACK_DIR/.env"

if ! ip link show wg0 >/dev/null 2>&1; then
    log "wg0 not active, skipping"
    exit 0
fi
if [ -z "${CLUSTER_NODES:-}" ]; then
    log "ERROR: CLUSTER_NODES missing in .env"
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
resolve_one() {
    # $1 = fqdn, $2 = af (v4|v6|auto)
    local fqdn="$1" af="$2" out=""
    case "$af" in
        v4)
            out="$(getent ahostsv4 "$fqdn" 2>/dev/null | awk 'NR==1{print $1}')"
            ;;
        v6)
            out="$(getent ahostsv6 "$fqdn" 2>/dev/null | awk 'NR==1{print $1}')"
            ;;
        auto|*)
            # Prefer AAAA, fallback to A
            out="$(getent ahostsv6 "$fqdn" 2>/dev/null | awk 'NR==1{print $1}')"
            if [ -z "$out" ]; then
                out="$(getent ahostsv4 "$fqdn" 2>/dev/null | awk 'NR==1{print $1}')"
            fi
            ;;
    esac
    echo "$out"
}

# Format: bei IPv6 muss endpoint [v6]:port sein, bei v4 v4:port
format_endpoint() {
    local ip="$1" port="$2"
    case "$ip" in
        *:*) echo "[${ip}]:${port}" ;;
        *)   echo "${ip}:${port}" ;;
    esac
}

# Hole aktuellen Endpoint-IP eines Peers (ohne Port, ohne Klammern)
current_endpoint_ip() {
    local pubkey="$1"
    # 'wg show wg0 endpoints' liefert Zeilen "<pubkey>\t<ip>:<port>"
    local line ep
    line="$(wg show wg0 endpoints 2>/dev/null | awk -v k="$pubkey" '$1==k {print $2}')"
    [ -z "$line" ] && { echo ""; return; }
    # Strip port
    if [[ "$line" =~ ^\[([0-9a-f:]+)\]: ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "${line%:*}"
    fi
}

# ---------------------------------------------------------------------------
# Peers durchgehen
# ---------------------------------------------------------------------------
CHANGED=0
IFS=',' read -r -a _nodes <<<"$CLUSTER_NODES"
for peer in "${_nodes[@]}"; do
    peer="${peer## }"; peer="${peer%% }"
    [ -z "$peer" ] && continue
    [ "$peer" = "${NODE_NAME:-}" ] && continue

    PUBKEY_FILE="$STACK_DIR/wireguard/keys/publickey.${peer}"
    [ -f "$PUBKEY_FILE" ] || { log "Missing public key for $peer, skipping"; continue; }
    PUBKEY="$(cat "$PUBKEY_FILE")"

    PREFIX="$(echo "$peer" | tr '[:lower:]' '[:upper:]')"
    af_var="NODE_${PREFIX}_WG_AF"
    AF="${!af_var:-auto}"

    FQDN="${peer}.${NODE_FQDN_DOMAIN}"
    NEW_IP="$(resolve_one "$FQDN" "$AF")"

    if [ -z "$NEW_IP" ]; then
        log "WARN: DNS lookup failed for $FQDN ($AF)"
        continue
    fi

    CUR_IP="$(current_endpoint_ip "$PUBKEY")"

    if [ "$CUR_IP" = "$NEW_IP" ]; then
        # Kein Change
        continue
    fi

    NEW_EP="$(format_endpoint "$NEW_IP" 51820)"
    log "Update $peer: '$CUR_IP' -> '$NEW_IP' (FQDN $FQDN, AF $AF)"
    wg set wg0 peer "$PUBKEY" endpoint "$NEW_EP"
    CHANGED=1
done

if [ "$CHANGED" -eq 1 ]; then
    log "At least one peer endpoint was updated."
else
    log "No changes."
fi
