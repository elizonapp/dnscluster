#!/usr/bin/env bash
# =============================================================================
# sync-receive-pubkey.sh — Receives a WG public key from stdin (one line)
#
# Called on the target node as:
#   sudo -u dockeruseragent .../sync-receive-pubkey.sh <peer>
#
# cluster-sync.sh distribute-pubkey uses this instead of scp so ns-cluster-sync
# doesn't need to write into wireguard/keys directly (permissions/chmod issues).
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."
. "$(dirname "$0")/env-load.sh"
load_env .env

PEER="${1:-}"
if [ -z "${CLUSTER_NODES:-}" ]; then
    echo "CLUSTER_NODES missing in .env" >&2
    exit 1
fi
case ",${CLUSTER_NODES}," in
    *,"${PEER}",*) : ;;
    *) echo "usage: sync-receive-pubkey.sh <peer>; peer must be included in CLUSTER_NODES (${CLUSTER_NODES})" >&2; exit 1 ;;
esac

mkdir -p wireguard/keys
DEST="wireguard/keys/publickey.${PEER}"
umask 022
cat >"$DEST"
chmod 644 "$DEST"
