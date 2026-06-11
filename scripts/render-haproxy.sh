#!/bin/sh
set -eu

TPL="${1:-/usr/local/etc/haproxy/haproxy.cfg.tpl}"
OUT="${2:-/tmp/haproxy.cfg}"

: "${CLUSTER_NODES:?CLUSTER_NODES missing}"

servers=""
oldIFS=$IFS
IFS=,
for n in $CLUSTER_NODES; do
  # trim
  n=$(printf "%s" "$n" | sed 's/^ *//;s/ *$//')
  [ -z "$n" ] && continue
  up=$(printf "%s" "$n" | tr '[:lower:]' '[:upper:]')
  ip_var="NODE_${up}_WG_IP"
  eval ip=\${$ip_var:-}
  [ -z "${ip:-}" ] && continue
  servers="${servers}    server ${n} ${ip}:5432 maxconn 200 check port 8008
"
done
IFS=$oldIFS

if [ -z "$servers" ]; then
  echo "render-haproxy: no servers generated (check NODE_<NODE>_WG_IP vars)" >&2
  exit 1
fi

# Replace placeholder (real newlines — not literal "\n")
awk -v block="$servers" '
  index($0, "__SERVERS__") { printf "%s", block; next }
  { print }
' "$TPL" > "$OUT"

exec haproxy -f "$OUT"

