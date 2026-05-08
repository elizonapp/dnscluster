#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh - Generates missing passwords and updates
#                pgbouncer/userlist.txt with the hashes.
#
# Idempotent: only values with "CHANGE_ME_*" are replaced; existing
# passwords are left untouched.
#
# IMPORTANT: generated passwords contain NO characters that typically break
# Docker-Compose ${VAR} substitution or shell parsing (no $, no quotes).
# If you want to set your own passwords, stick to alphanumeric plus - _ .
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "Missing: .env"; exit 1; }
. "$(dirname "$0")/env-load.sh"

# ---------------------------------------------------------------------------
# Helper: set value in .env (replace existing line, otherwise append)
# ---------------------------------------------------------------------------
set_env_value() {
    local key="$1" val="$2"
    if grep -q "^${key}=" .env; then
        # Use | as sed delimiter because val may contain /
        # Keep val printf-safe (no extra escaping needed because we avoid $/&)
        local esc_val
        esc_val=$(printf '%s\n' "$val" | sed -e 's/[\/&|]/\\&/g')
        sed -i "s|^${key}=.*|${key}=${esc_val}|" .env
    else
        echo "${key}=${val}" >> .env
    fi
}

# Safe random passwords: alphanumeric + - _, no special characters
gen_password() {
    local len="${1:-32}"
    # base64 would include / + =; tr filters those out
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9_-' | head -c "$len"
}

# ---------------------------------------------------------------------------
# Auto-fill all CHANGE_ME_* values in .env
# ---------------------------------------------------------------------------
load_env .env

declare -A SECRETS=(
    [POSTGRES_SUPERUSER_PASSWORD]=32
    [POSTGRES_REPLICATION_PASSWORD]=32
    [POSTGRES_REWIND_PASSWORD]=32
    [PATRONI_REST_PASSWORD]=32
    [PDNS_DB_PASSWORD]=32
    [PDNS_API_KEY]=48
    [PDNS_ADMIN_SECRET_KEY]=48
    [PDNS_ADMIN_SALT]=24
    [GRAFANA_ADMIN_PASSWORD]=24
)

CHANGED=0
for key in "${!SECRETS[@]}"; do
    current="${!key:-}"
    if [ -z "$current" ] || [[ "$current" == CHANGE_ME_* ]]; then
        new_val="$(gen_password "${SECRETS[$key]}")"
        set_env_value "$key" "$new_val"
        echo "==> Generated $key (length ${SECRETS[$key]})"
        # Reload env for subsequent steps
        export "$key=$new_val"
        CHANGED=1
    fi
done

# Warn if the user put special characters into passwords
load_env .env
for key in "${!SECRETS[@]}"; do
    val="${!key:-}"
    case "$val" in
        *'$'*|*'`'*|*'"'*|*"'"*)
            echo "WARNING: $key contains special characters (\$,\`,\",'). This can"
            echo "         break Docker Compose or shells."
            echo "         Recommendation: set a new password, or set"
            echo "         '${key}=' to empty in .env and rerun bootstrap.sh"
            echo "         (it will auto-generate a safe one)."
            ;;
    esac
done

if [ "$CHANGED" -eq 1 ]; then
    echo "==> Passwords updated in .env."
fi

# ---------------------------------------------------------------------------
# pgbouncer userlist.txt
# ---------------------------------------------------------------------------
: "${PDNS_DB_PASSWORD:?PDNS_DB_PASSWORD not set}"
: "${POSTGRES_SUPERUSER_PASSWORD:?POSTGRES_SUPERUSER_PASSWORD not set}"

pdns_hash="md5$(echo -n "${PDNS_DB_PASSWORD}pdns" | md5sum | awk '{print $1}')"
pg_hash="md5$(echo -n "${POSTGRES_SUPERUSER_PASSWORD}postgres" | md5sum | awk '{print $1}')"

cat > pgbouncer/userlist.txt <<EOF
"pdns" "${pdns_hash}"
"postgres" "${pg_hash}"
EOF

echo "==> Updated pgbouncer/userlist.txt."

# Align PostgreSQL role 'pdns' password — only on the leader (local Postgres, not via HAProxy->replica)
if docker compose exec -T patroni curl -sf -o /dev/null http://127.0.0.1:8008/primary 2>/dev/null; then
  pw_esc=$(printf '%s' "$PDNS_DB_PASSWORD" | sed "s/'/''/g")
  if docker compose exec -T patroni psql -U postgres -h 127.0.0.1 -v ON_ERROR_STOP=1 \
    -c "ALTER ROLE pdns WITH PASSWORD '${pw_esc}';"; then
    echo "==> PostgreSQL ALTER ROLE pdns executed."
  else
    echo "==> ALTER ROLE failed — manual: bash scripts/sync-pdns-postgres-password.sh"
  fi
else
  echo "==> No leader on this host — after the stack is up, run on the leader:"
  echo "    bash scripts/sync-pdns-postgres-password.sh"
fi

echo
echo "Reminder - Grafana login:"
echo "  user: admin"
echo "  pass: $GRAFANA_ADMIN_PASSWORD"
