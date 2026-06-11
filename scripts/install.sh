#!/usr/bin/env bash
# =============================================================================
# install.sh - Provisions a fresh Debian/Ubuntu host for the
#              DNS cluster stack (system-wide Docker, not rootless).
#
# Universal (node identity via --node or
# interaktiv abgefragt.
#
# Phases:
#   1) Basis-Pakete
#   2) Docker via get.docker.com
#   3) Service-User 'dockeruseragent' anlegen
#   4) Stack nach /home/dockeruseragent/dnscluster verschieben
#   5) sysctl
#   6) systemd-resolved: DNSStubListener=no (consistent public DNS for WG FQDNs)
#   7) WireGuard:
#       - wg-reresolve.sh nach /usr/local/sbin/ kopieren
#       - systemd-Timer wg-reresolve installieren
#       - /etc/wireguard/wg0.conf via wireguard-render.sh erzeugen
#       - wg-quick@wg0 enabled (wird aber erst aktiv, wenn Peer-Keys da sind)
#   8) SSH-Sync-User 'ns-cluster-sync' anlegen mit forced-command
#   9) ufw (optional)
#
# Usage:
#   sudo ./scripts/install.sh --node ns1
#   sudo ./scripts/install.sh --node ns2 --with-firewall
#   sudo ./scripts/install.sh --node ns3 --skip-docker
# =============================================================================
set -euo pipefail

NODE_ARG=""
WITH_FIREWALL=0
SKIP_DOCKER=0

while [ $# -gt 0 ]; do
    case "$1" in
        --node)           NODE_ARG="$2"; shift 2 ;;
        --node=*)         NODE_ARG="${1#--node=}"; shift ;;
        --with-firewall)  WITH_FIREWALL=1; shift ;;
        --skip-docker)    SKIP_DOCKER=1; shift ;;
        -h|--help)        sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

[ "$EUID" -eq 0 ] || { echo "Please run as root." >&2; exit 1; }

if [ ! -f /etc/os-release ]; then
    echo "No /etc/os-release - unsupported system." >&2; exit 1
fi
. /etc/os-release
case "${ID:-}" in debian|ubuntu) : ;; *) echo "Debian/Ubuntu only."; exit 1 ;; esac

# Determine node identity
if [ -z "$NODE_ARG" ]; then
    echo "Which node is this? (must be listed in CLUSTER_NODES in .env)"
    read -r NODE_ARG
fi
if [ ! -f "$(cd "$(dirname "$0")/.." && pwd)/.env" ]; then
    echo "Missing: .env. Run ./scripts/first-use.sh init first (or create .env manually)." >&2
    exit 1
fi
. "$(cd "$(dirname "$0")/.." && pwd)/scripts/env-load.sh"
load_env "$(cd "$(dirname "$0")/.." && pwd)/.env"
: "${CLUSTER_NODES:?CLUSTER_NODES missing in .env}"
case ",${CLUSTER_NODES}," in
    *,"${NODE_ARG}",*) : ;;
    *) echo "--node must be included in CLUSTER_NODES: ${CLUSTER_NODES}" >&2; exit 1 ;;
esac

echo "==> Detected: $PRETTY_NAME / Node: $NODE_ARG"
export DEBIAN_FRONTEND=noninteractive

SERVICE_USER="dockeruseragent"
SSH_SYNC_USER="ns-cluster-sync"
STACK_DIR_TARGET="/home/${SERVICE_USER}/dnscluster"
STACK_DIR_SOURCE="$(cd "$(dirname "$0")/.." && pwd)"

# ---------------------------------------------------------------------------
# 1) Basis-Pakete
# ---------------------------------------------------------------------------
echo "==> apt update + Basis-Tools"
apt-get update -qq
apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release \
    jq dnsutils gettext-base openssl \
    wireguard-tools \
    postgresql-client-common postgresql-client \
    htop iproute2 net-tools git rsync \
    openssh-client \
    >/dev/null

# ---------------------------------------------------------------------------
# 2) Docker
# ---------------------------------------------------------------------------
if [ "$SKIP_DOCKER" -eq 0 ]; then
    if ! command -v docker >/dev/null 2>&1; then
        echo "==> Installing Docker (get.docker.com)"
        curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    fi
    echo "==> Ensuring Docker daemon is running"
    systemctl enable --now docker.service >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# 3) Service-User
# ---------------------------------------------------------------------------
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    echo "==> Creating user '$SERVICE_USER'"
    useradd -m -s /bin/bash "$SERVICE_USER"
    GEN_PASS="$(openssl rand -base64 24 | tr -d '/+=')"
    echo "${SERVICE_USER}:${GEN_PASS}" | chpasswd
    cat > /root/${SERVICE_USER}.password <<EOF
# Auto-generated password for ${SERVICE_USER}
# $(date -Iseconds)
${GEN_PASS}
EOF
    chmod 600 /root/${SERVICE_USER}.password
    echo "    Password -> /root/${SERVICE_USER}.password"
else
    # User existiert bereits - sicherstellen, dass die Shell bash ist
    # (some earlier setup snippets used /usr/sbin/nologin).
    CURRENT_SHELL="$(getent passwd "$SERVICE_USER" | cut -d: -f7)"
    if [ "$CURRENT_SHELL" != "/bin/bash" ]; then
        echo "==> Fixing shell for '$SERVICE_USER' (was: $CURRENT_SHELL)"
        usermod -s /bin/bash "$SERVICE_USER"
    fi
    # Home muss existieren (bei nologin-Useraccount evtl. nicht der Fall)
    HOME_DIR="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
    if [ ! -d "$HOME_DIR" ]; then
        echo "==> Creating home directory $HOME_DIR"
        mkhomedir_helper "$SERVICE_USER" 2>/dev/null || {
            install -d -m 750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$HOME_DIR"
        }
    fi
fi
if getent group docker >/dev/null 2>&1; then
    usermod -aG docker "$SERVICE_USER" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 4) Stack nach /home/dockeruseragent/
# ---------------------------------------------------------------------------
if [ "$STACK_DIR_SOURCE" != "$STACK_DIR_TARGET" ]; then
    echo "==> Copying stack to $STACK_DIR_TARGET"
    if [ -d "$STACK_DIR_TARGET" ]; then
        # on reinstall: overwrite only code/configs, NOT keys/, NOT .env
        rsync -a --exclude='wireguard/keys/' --exclude='.env' \
              "$STACK_DIR_SOURCE/" "$STACK_DIR_TARGET/"
    else
        cp -a "$STACK_DIR_SOURCE" "$STACK_DIR_TARGET"
    fi
    chown -R "$SERVICE_USER:$SERVICE_USER" "$STACK_DIR_TARGET"
fi

# .env aus Vorlage initialisieren falls fehlt
if [ ! -f "$STACK_DIR_TARGET/.env" ]; then
    cp "$STACK_DIR_TARGET/.env.example" "$STACK_DIR_TARGET/.env"
    chown "$SERVICE_USER:$SERVICE_USER" "$STACK_DIR_TARGET/.env"
fi

# Node-spezifische Werte einsetzen
echo "==> Initializing node identity ($NODE_ARG)"
runuser -u "$SERVICE_USER" -- bash -c "cd '$STACK_DIR_TARGET' && ./scripts/node-init.sh '$NODE_ARG'"

# ---------------------------------------------------------------------------
# 5) sysctl
# ---------------------------------------------------------------------------
echo "==> sysctl-Tuning"
cat > /etc/sysctl.d/99-dnscluster.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
kernel.shmmax = 17179869184
kernel.shmall = 4194304
vm.overcommit_memory = 2
vm.overcommit_ratio = 80
vm.swappiness = 10
EOF
sysctl --system >/dev/null

# ---------------------------------------------------------------------------
# 6) systemd-resolved: disable local DNS stub (127.0.0.53)
# ---------------------------------------------------------------------------
RESOLVED_CONF=/etc/systemd/resolved.conf
if [ -f "$RESOLVED_CONF" ] && grep -q '^\[Resolve\]' "$RESOLVED_CONF"; then
    echo "==> Configuring $RESOLVED_CONF (DNSStubListener=no)"
    if grep -qE '^DNSStubListener=no' "$RESOLVED_CONF"; then
        echo "    DNSStubListener=no already set"
    elif grep -qE '^#?DNSStubListener=' "$RESOLVED_CONF" \
        || grep -qE '^# DNSStubListener=' "$RESOLVED_CONF"; then
        sed -i -E \
            -e 's/^#?DNSStubListener=.*/DNSStubListener=no/' \
            -e 's/^# DNSStubListener=.*/DNSStubListener=no/' \
            "$RESOLVED_CONF"
        echo "    Replaced DNSStubListener=… with DNSStubListener=no"
    else
        printf '\nDNSStubListener=no\n' >> "$RESOLVED_CONF"
        echo "    Appended DNSStubListener=no"
    fi
    if systemctl is-enabled systemd-resolved >/dev/null 2>&1; then
        systemctl restart systemd-resolved
        echo "    Restarted systemd-resolved"
    fi
else
    echo "==> Skipping $RESOLVED_CONF (missing or no [Resolve] section)"
fi

# ---------------------------------------------------------------------------
# 7) WireGuard + Reresolve
# ---------------------------------------------------------------------------
echo "==> Installing wg-reresolve.sh + systemd timer"
install -m 750 -o root -g root \
    "$STACK_DIR_TARGET/scripts/wg-reresolve.sh" \
    /usr/local/sbin/wg-reresolve.sh

cat > /etc/default/dnscluster <<EOF
# Stack location for wg-reresolve.service
STACK_DIR=$STACK_DIR_TARGET
EOF

install -m 644 \
    "$STACK_DIR_TARGET/scripts/systemd/wg-reresolve.service" \
    /etc/systemd/system/wg-reresolve.service
install -m 644 \
    "$STACK_DIR_TARGET/scripts/systemd/wg-reresolve.timer" \
    /etc/systemd/system/wg-reresolve.timer

systemctl daemon-reload
systemctl enable wg-reresolve.timer

# WG-Config rendern. Der Render-Script erzeugt Keys in
# wireguard/keys/ und schreibt /etc/wireguard/wg0.conf. Damit die Keys danach
# To keep keys owned by the service user, we render as that user AND then run as root
# again to write into /etc/wireguard/.
echo "==> Creating WG keys (as $SERVICE_USER) and rendering wg0.conf"
runuser -u "$SERVICE_USER" -- bash -c "cd '$STACK_DIR_TARGET' && ./scripts/wireguard-render.sh --print >/dev/null"
# Der --print-Aufruf hat die Keys angelegt (falls noch nicht da). Jetzt als root
# das eigentliche Schreiben nach /etc/wireguard/.
"$STACK_DIR_TARGET/scripts/wireguard-render.sh" || \
    echo "    -> wg0.conf is likely incomplete (peer keys missing)"

# Ensure keys are owned by the service user
chown -R "$SERVICE_USER:$SERVICE_USER" "$STACK_DIR_TARGET/wireguard/keys" 2>/dev/null || true

# wg-quick@wg0 enablen (kann erst sauber up gehen, wenn alle Peer-Keys da sind)
systemctl enable wg-quick@wg0 2>/dev/null || true

# ---------------------------------------------------------------------------
# 8) SSH-Sync-User
# ---------------------------------------------------------------------------
echo "==> Creating SSH sync user '$SSH_SYNC_USER'"
if ! id "$SSH_SYNC_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$SSH_SYNC_USER"
else
    # Ohne Login-Shell schlagen ssh … 'remote-command' und cluster-sync.sh fehl (nologin beendet sofort).
    CURRENT_SHELL="$(getent passwd "$SSH_SYNC_USER" | cut -d: -f7)"
    if [ "$CURRENT_SHELL" != "/bin/bash" ]; then
        echo "==> Fixing shell for '$SSH_SYNC_USER' (was: $CURRENT_SHELL)"
        usermod -s /bin/bash "$SSH_SYNC_USER"
    fi
    HOME_DIR="$(getent passwd "$SSH_SYNC_USER" | cut -d: -f6)"
    if [ ! -d "$HOME_DIR" ]; then
        echo "==> Creating home directory $HOME_DIR"
        mkhomedir_helper "$SSH_SYNC_USER" 2>/dev/null || {
            install -d -m 750 -o "$SSH_SYNC_USER" -g "$SSH_SYNC_USER" "$HOME_DIR"
        }
    fi
fi

# Sync user: no plaintext password needed (SSH keys only). sudo below is NOPASSWD for fixed commands.
SUDOERS=/etc/sudoers.d/${SSH_SYNC_USER}
cat > "$SUDOERS" <<EOF
# Erlaubt dem Sync-User feste Befehle: reresolve + wireguard-render (muss root sein) + Pubkey (als ${SERVICE_USER})
${SSH_SYNC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/wg-reresolve.sh
${SSH_SYNC_USER} ALL=(root) NOPASSWD: /home/${SERVICE_USER}/dnscluster/scripts/wireguard-render.sh
${SSH_SYNC_USER} ALL=(${SERVICE_USER}) NOPASSWD: /home/${SERVICE_USER}/dnscluster/scripts/sync-receive-pubkey.sh
EOF
chmod 440 "$SUDOERS"
visudo -cf "$SUDOERS" >/dev/null

# Sync user can write into dnscluster/wireguard/keys/ (for distribute-pubkey)
# and edit .env
install -d -m 770 -o "$SERVICE_USER" -g "$SSH_SYNC_USER" "$STACK_DIR_TARGET/wireguard/keys"
chmod g+w "$STACK_DIR_TARGET/.env"
chgrp "$SSH_SYNC_USER" "$STACK_DIR_TARGET/.env"

# Homedir von $SERVICE_USER ist typisch 700 — ohne „others“+x darf $SSH_SYNC_USER den
# Pfad zu wireguard/keys nicht traversieren (scp distribute-pubkey: Permission denied).
SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
chmod o+x "$SERVICE_HOME"

# Stack ist oft 750 (Owner/Gruppe dockeruseragent): $SSH_SYNC_USER ist weder Owner noch in
# dockeruseragent → braucht „others“+x auf jedem Pfadsegment bis wireguard/keys/.
chmod o+x "$STACK_DIR_TARGET" "$STACK_DIR_TARGET/wireguard"

# Generate SSH key for sync operations (for dockeruseragent)
runuser -u "$SERVICE_USER" -- bash <<'INNER'
export HOME="$(getent passwd "$(id -un)" | cut -d: -f6)"
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
if [ ! -f "$HOME/.ssh/cluster_sync_ed25519" ]; then
    ssh-keygen -t ed25519 -N '' -f "$HOME/.ssh/cluster_sync_ed25519" -C "cluster-sync@$(hostname -s)"
fi
INNER

SYNC_PUBKEY="$(cat /home/${SERVICE_USER}/.ssh/cluster_sync_ed25519.pub)"
echo
echo "==> Sync-PublicKey dieses Nodes:"
echo "    $SYNC_PUBKEY"
echo

# Eigene authorized_keys: Trusted Sync-Keys aus den anderen Nodes
mkdir -p /home/${SSH_SYNC_USER}/.ssh
chmod 700 /home/${SSH_SYNC_USER}/.ssh
touch /home/${SSH_SYNC_USER}/.ssh/authorized_keys
chmod 600 /home/${SSH_SYNC_USER}/.ssh/authorized_keys
chown -R "$SSH_SYNC_USER:$SSH_SYNC_USER" /home/${SSH_SYNC_USER}/.ssh

# ---------------------------------------------------------------------------
# 9) ufw
# ---------------------------------------------------------------------------
if [ "$WITH_FIREWALL" -eq 1 ]; then
    echo "==> Configuring ufw"
    apt-get install -y --no-install-recommends ufw >/dev/null
    ufw --force reset >/dev/null
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp     comment 'SSH'
    ufw allow 53/udp     comment 'DNS'
    ufw allow 53/tcp     comment 'DNS-TCP'
    ufw allow 51820/udp  comment 'WireGuard'
    ufw allow 80/tcp     comment 'HTTP (Caddy + ACME-Challenge)'
    ufw allow 443/tcp    comment 'HTTPS (Caddy)'
    ufw allow 443/udp    comment 'HTTP/3 (Caddy)'
    # 9191 (PDA) und 3000 (Grafana) NICHT mehr offen - laufen nur intern via Caddy
    ufw --force enable
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
cat <<EOF

============================================================
 Installation completed for $NODE_ARG.
============================================================
 Service-User:        $SERVICE_USER
 SSH-Sync-User:       $SSH_SYNC_USER
 Stack:               $STACK_DIR_TARGET
 Docker:              systemweit
 Reresolve-Timer:     wg-reresolve.timer (alle 5 min)

 Next steps:

   1) If install.sh already ran on the other nodes, add their SSH sync public keys
      here into
        /home/${SSH_SYNC_USER}/.ssh/authorized_keys
      (one line per peer).

   2) Distribute WG public keys between nodes.
      After the first install (SSH sync not authorized yet), do it manually:
        cat /home/${SERVICE_USER}/dnscluster/wireguard/keys/publickey
      and store it on the other nodes as
        wireguard/keys/publickey.${NODE_ARG}
      then run 'sudo ./scripts/wireguard-render.sh' there.

      Once SSH sync works, you can do:
        sudo -iu $SERVICE_USER
        cd ~/dnscluster
        ./scripts/cluster-sync.sh distribute-pubkey

   3) Once all peer keys are present:
        systemctl restart wg-quick@wg0
        systemctl status wg-quick@wg0
        ip a show wg0

   4) Bring up the stack (on EACH node):
        sudo -iu $SERVICE_USER
        cd ~/dnscluster
        nano .env                        # set passwords
        ./scripts/bootstrap.sh
        docker compose build patroni
        docker compose up -d

   5) Database schema ONLY when Patroni is healthy and Postgres responds (typically on the leader):
        docker compose exec -T patroni psql -U postgres -h 127.0.0.1 -f - < scripts/init-databases.sql
        # Single line; do not use line continuation with \\.

============================================================
EOF
