#!/usr/bin/env bash
# =============================================================================
# env-load.sh - Safe loading of .env files
#
# Intended to be sourced by other scripts:
#   . "$(dirname "$0")/env-load.sh"
#   load_env .env
#
# Unlike 'set -a; . .env; set +a', this loader does NOT interpret values as
# shell code. This matters because passwords may contain special characters
# like $5, $(...), `...` or ! (bcrypt hashes, openssl output, etc.).
# =============================================================================

load_env() {
    local file="${1:-.env}"
    [ -f "$file" ] || { echo "load_env: missing $file" >&2; return 1; }

    local line key val
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        case "$line" in
            ''|\#*) continue ;;
        esac
        # Skip marker lines from node-init.sh
        case "$line" in
            '# >>>'*|'# <<<'*) continue ;;
        esac
        # Must be KEY=...
        case "$line" in
            *=*) : ;;
            *) continue ;;
        esac

        key="${line%%=*}"
        val="${line#*=}"

        # Trim whitespace around the key
        key="${key# }"; key="${key% }"

        # Allow optional 'export ' prefix
        case "$key" in
            'export '*) key="${key#export }" ;;
        esac

        # Validate key (only [A-Za-z_][A-Za-z0-9_]*)
        case "$key" in
            [a-zA-Z_]*)
                # Strip surrounding quotes if present
                if [ "${val#\"}" != "$val" ] && [ "${val%\"}" != "$val" ]; then
                    val="${val#\"}"; val="${val%\"}"
                elif [ "${val#\'}" != "$val" ] && [ "${val%\'}" != "$val" ]; then
                    val="${val#\'}"; val="${val%\'}"
                fi
                # Set + export directly WITHOUT shell eval
                export "${key}=${val}"
                ;;
            *) continue ;;
        esac
    done < "$file"
}
