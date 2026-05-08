#!/bin/sh
set -eu

TPL="${1:-/etc/prometheus/prometheus.yml.tpl}"
OUT="${2:-/etc/prometheus/prometheus.yml}"
TARGETS_OUT="${3:-/etc/prometheus/targets.json}"

: "${CLUSTER_NODES:?CLUSTER_NODES missing}"
: "${NODE_NAME:?NODE_NAME missing}"
: "${NODE_SITE:?NODE_SITE missing}"

render_targets() {
  printf "[" >"$TARGETS_OUT"
  first=1

  oldIFS=$IFS
  IFS=,
  for n in $CLUSTER_NODES; do
    n=$(printf "%s" "$n" | sed 's/^ *//;s/ *$//')
    [ -z "$n" ] && continue

    up=$(printf "%s" "$n" | tr '[:lower:]' '[:upper:]')
    ip_var="NODE_${up}_WG_IP"
    eval ip=\${$ip_var:-}
    [ -z "${ip:-}" ] && continue

    targets=$(printf "%s" "${ip}:9100,${ip}:9187,${ip}:9120,${ip}:8008,${ip}:2379" | sed 's/,/","/g')

    [ "$first" -eq 1 ] || printf "," >>"$TARGETS_OUT"
    first=0
    printf "\n  {\"targets\":[\"%s\"],\"labels\":{\"node\":\"%s\"}}" "$targets" "$n" >>"$TARGETS_OUT"
  done
  IFS=$oldIFS

  printf "\n]\n" >>"$TARGETS_OUT"
}

render_targets

# prom image doesn't ship envsubst; keep template as-is except it already uses ${NODE_*}
# we do minimal sed replacements for known vars
sed \
  -e "s|\${NODE_SITE}|${NODE_SITE}|g" \
  -e "s|\${NODE_NAME}|${NODE_NAME}|g" \
  "$TPL" >"$OUT"

exec /bin/prometheus \
  --config.file="$OUT" \
  --storage.tsdb.path=/prometheus \
  --storage.tsdb.retention.time=30d \
  --web.enable-lifecycle

