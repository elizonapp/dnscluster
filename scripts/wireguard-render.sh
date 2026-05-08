#!/usr/bin/env bash
# =============================================================================
# wireguard-render.sh - Creates /etc/wireguard/wg0.conf from
#                       wireguard/wg0.conf.tpl + .env values
#
# For each peer (all ns* != NODE_NAME), add a [Peer] block with an FQDN endpoint.
# If /etc/wireguard/wg0.conf exists, it keeps the existing PrivateKey (no regen).
#
# If wg0 is already up, apply the new config via 'wg syncconf'
# - this updates peers WITHOUT interrupting the tunnel.
#
# Usage:
#   sudo ./scripts/wireguard-render.sh           # render + apply
#   sudo ./scripts/wireguard-render.sh --print   # print only, don't write
#
# Requirements: the script must run as root (for /etc/wireguard) and
# .env must already contain NODE_NAME (via node-init.sh).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

PRINT_ONLY=0
[ "${1:-}" = "--print" ] && PRINT_ONLY=1

if [ "$PRINT_ONLY" -eq 0 ] && [ "$EUID" -ne 0 ]; then
    echo "Please run as root (for /etc/wireguard/wg0.conf)." >&2
    exit 1
fi

if [ ! -f .env ]; then
    echo "Missing: .env (run ./scripts/node-init.sh first)" >&2
    exit 1
fi

. "$(dirname "$0")/env-load.sh"
load_env .env

if [ -z "${NODE_NAME:-}" ] || [ -z "${NODE_WG_IP:-}" ]; then
    echo "NODE_NAME / NODE_WG_IP not set in .env -> run ./scripts/node-init.sh <node>" >&2
    exit 1
fi
if [ -z "${CLUSTER_NODES:-}" ]; then
    echo "CLUSTER_NODES missing in .env (e.g. CLUSTER_NODES=ns1,ns2,ns3,ns4)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Privaten Key beschaffen
# ---------------------------------------------------------------------------
mkdir -p wireguard/keys
SERVICE_USER="dockeruseragent"
SSH_SYNC_USER="${SYNC_SSH_USER:-ns-cluster-sync}"
# install.sh legt keys als 770 + Gruppe ns-cluster-sync an (scp distribute-pubkey).
# chmod 700 here would break follow-up runs — only root should enforce sync permissions.
if [ "$EUID" -eq 0 ]; then
    chown "${SERVICE_USER}:${SSH_SYNC_USER}" wireguard/keys
    chmod 770 wireguard/keys
else
    chmod 700 wireguard/keys
fi

if [ ! -f wireguard/keys/privatekey ]; then
    echo "==> Generate new WireGuard keypair"
    umask 077
    wg genkey | tee wireguard/keys/privatekey | wg pubkey > wireguard/keys/publickey
    chmod 600 wireguard/keys/privatekey
fi
if [ "$EUID" -eq 0 ]; then
    chown "${SERVICE_USER}:${SERVICE_USER}" wireguard/keys/privatekey wireguard/keys/publickey
    chmod 600 wireguard/keys/privatekey
fi
PRIVATE_KEY="$(cat wireguard/keys/privatekey)"

# ---------------------------------------------------------------------------
# List peers (all ns* except self)
# ---------------------------------------------------------------------------
PEER_BLOCKS=""
IFS=',' read -r -a _nodes <<<"$CLUSTER_NODES"
for peer in "${_nodes[@]}"; do
    peer="${peer## }"; peer="${peer%% }"
    [ -z "$peer" ] && continue
    [ "$peer" = "$NODE_NAME" ] && continue

    P_PREFIX="$(echo "$peer" | tr '[:lower:]' '[:upper:]')"
    p_wg_ip_var="NODE_${P_PREFIX}_WG_IP"
    p_wg_af_var="NODE_${P_PREFIX}_WG_AF"
    P_WG_IP="${!p_wg_ip_var:-}"
    P_WG_AF="${!p_wg_af_var:-auto}"

    if [ -z "$P_WG_IP" ]; then
        echo "WARN: $peer has no WG IP in .env, skipping."
        continue
    fi

    P_FQDN="${peer}.${NODE_FQDN_DOMAIN}"

    # Public-Key des Peers wird aus wireguard/keys/publickey.<peer> gelesen,
    # falls vorhanden; sonst Platzhalter.
    if [ -f "wireguard/keys/publickey.${peer}" ]; then
        P_PUBKEY="$(cat "wireguard/keys/publickey.${peer}")"
    else
        P_PUBKEY="REPLACE_WITH_${P_PREFIX}_PUBLIC_KEY"
        echo "WARN: wireguard/keys/publickey.${peer} missing - placeholder inserted"
    fi

    # WG-Endpoint: FQDN:Port. wg-quick versteht das.
    # Adressfamilie steuern wir bei resolve-time im Reresolve-Script
    # (siehe wg-reresolve.sh) - in der Config selbst FQDN reicht.
    P_ENDPOINT="${P_FQDN}:51820"

    PEER_BLOCKS+="

[Peer]
# ${peer} (${P_FQDN})  -  Adress-Familie: ${P_WG_AF}
PublicKey  = ${P_PUBKEY}
AllowedIPs = ${P_WG_IP}/32
Endpoint   = ${P_ENDPOINT}
PersistentKeepalive = 25"
done

# ---------------------------------------------------------------------------
# Template rendern
# ---------------------------------------------------------------------------
TPL=wireguard/wg0.conf.tpl
[ -f "$TPL" ] || { echo "$TPL fehlt"; exit 1; }

OUTPUT="$(cat "$TPL")"
OUTPUT="${OUTPUT//__WG_ADDRESS__/$NODE_WG_IP}"
OUTPUT="${OUTPUT//__PRIVATE_KEY__/$PRIVATE_KEY}"

# Peer-Block-Range ersetzen
OUTPUT="$(awk -v block="$PEER_BLOCKS" '
    /# >>> PEER_BLOCKS_BEGIN >>>/ { print; print block; in_block=1; next }
    /# <<< PEER_BLOCKS_END <<</   { in_block=0; print; next }
    !in_block { print }
' <<< "$OUTPUT")"

if [ "$PRINT_ONLY" -eq 1 ]; then
    echo "$OUTPUT"
    exit 0
fi

# ---------------------------------------------------------------------------
# Schreiben
# ---------------------------------------------------------------------------
install -d -m 700 /etc/wireguard
TARGET=/etc/wireguard/wg0.conf

# Only replace if something changed
if [ -f "$TARGET" ] && diff -q <(echo "$OUTPUT") "$TARGET" >/dev/null 2>&1; then
    echo "==> /etc/wireguard/wg0.conf already up to date"
    exit 0
fi

# Backup
[ -f "$TARGET" ] && cp -a "$TARGET" "${TARGET}.bak.$(date +%s)"

echo "$OUTPUT" > "$TARGET"
chmod 600 "$TARGET"
echo "==> Wrote /etc/wireguard/wg0.conf"

# ---------------------------------------------------------------------------
# Live-Apply via 'wg syncconf' (kein Tunnel-Drop)
# ---------------------------------------------------------------------------
if ip link show wg0 >/dev/null 2>&1; then
    echo "==> wg0 is up - applying via syncconf"
    # syncconf will eine *gestrippte* Conf (ohne wg-quick-spezifische Direktiven).
    # Wir generieren das on-the-fly.
    TMPCONF="$(mktemp)"
    wg-quick strip wg0 > "$TMPCONF"
    wg syncconf wg0 "$TMPCONF"
    rm -f "$TMPCONF"
    echo "    Peers updated without tunnel interruption."
else
    echo "==> wg0 not active - start with 'systemctl enable --now wg-quick@wg0'."
fi
