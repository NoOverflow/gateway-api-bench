#!/bin/bash
# Run every benchmark family sequentially and retain logs even on failures.
# Every test measures one gateway at a time (see the individual scripts) so an
# implementation under load cannot skew another implementation's numbers.
set -uo pipefail

WD=$(dirname "$0")
WD=$(cd "$WD"; pwd)
RESULTS_DIR="${RESULTS_DIR:-${WD}/../results}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM}"
LOG_DIR="${RESULTS_DIR}/logs/${RUN_ID}"
STATUS_FILE="${RESULTS_DIR}/run-${RUN_ID}-status.csv"

PROBE_ROUTES="${PROBE_ROUTES:-100}"
ATTACHED_ROUTES="${ATTACHED_ROUTES:-100}"
ROUTECHANGE_ITERATIONS="${ROUTECHANGE_ITERATIONS:-10}"
FAILOVER_ITERATIONS="${FAILOVER_ITERATIONS:-3}"
# Comma-separated failover policy variants to run after the baseline
# (directories under tests/backendfailover/policies). Empty disables variants.
FAILOVER_VARIANTS="${FAILOVER_VARIANTS-outlier}"
SCALE_DURATION="${SCALE_DURATION:-5m}"
ROUTE_LOAD_NAMESPACES="${ROUTE_LOAD_NAMESPACES:-10}"
ROUTE_LOAD_ROUTES="${ROUTE_LOAD_ROUTES:-100}"
LISTENERSET_NAMESPACES="${LISTENERSET_NAMESPACES:-10}"
LISTENERSETS="${LISTENERSETS:-10}"
TRAFFIC_DURATION="${TRAFFIC_DURATION:-30}"
TRAFFIC_CONNECTIONS="${TRAFFIC_CONNECTIONS:-1,8,16,32,64,128,256}"
TRAFFIC_PAYLOAD="${TRAFFIC_PAYLOAD:-100}"

# Comma-separated subset of steps to run (default: all), e.g. to resume a run:
#   RUN_ID=<same id> RUN_STEPS=routechange,backendfailover,traffic ./tests/run-all.sh
# "traffic" expands to every connection count; "backendfailover" includes the
# variants. Re-running a step appends to the existing status file.
RUN_STEPS="${RUN_STEPS:-attached-routes,probe,routechange,backendfailover,route-load,listenerset-load,traffic}"

mkdir -p "$LOG_DIR"
[[ -s "$STATUS_FILE" ]] || printf 'test,status,duration_seconds,log\n' >"$STATUS_FILE"

# Record which implementation versions produced these results.
{
  echo "# gateway versions for run ${RUN_ID} ($(date -u +%FT%TZ))"
  echo "release,namespace,chart,app_version"
  helm list -A -o json 2>/dev/null | python3 -c 'import json,sys
for r in json.load(sys.stdin): print(",".join([r["name"], r["namespace"], r["chart"], r["app_version"]]))'
  echo "gateway-api,,$(kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null),$(kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/channel}' 2>/dev/null)"
} >"${RESULTS_DIR}/versions-${RUN_ID}.csv"

wants() { [[ ",${RUN_STEPS}," == *",$1,"* ]]; }

run_step() {
  local name="$1"
  shift
  local log="${LOG_DIR}/${name}.log"
  local start end rc
  echo "[$(date -u +%FT%TZ)] ${name}: starting" >&2
  start=$(date +%s)
  if "$@" >"$log" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  end=$(date +%s)
  if [[ "$rc" -eq 0 ]]; then
    printf '%s,passed,%s,%s\n' "$name" "$((end - start))" "$log" >>"$STATUS_FILE"
    echo "[$(date -u +%FT%TZ)] ${name}: passed in $((end - start))s" >&2
  else
    printf '%s,failed:%s,%s,%s\n' "$name" "$rc" "$((end - start))" "$log" >>"$STATUS_FILE"
    echo "[$(date -u +%FT%TZ)] ${name}: FAILED (rc=${rc}) after $((end - start))s, see ${log}" >&2
  fi
}

export RESULTS_DIR

wants attached-routes && run_step attached-routes "$WD/attached-routes.sh" --routes="$ATTACHED_ROUTES"
wants probe && run_step probe "$WD/probe.sh" --routes="$PROBE_ROUTES"
wants routechange && run_step routechange "$WD/routechange.sh" --iterations="$ROUTECHANGE_ITERATIONS"
if wants backendfailover; then
  run_step backendfailover "$WD/backendfailover.sh" --iterations="$FAILOVER_ITERATIONS"
  if [[ -n "$FAILOVER_VARIANTS" ]]; then
    IFS=',' read -r -a variants <<< "$FAILOVER_VARIANTS"
    for variant in "${variants[@]}"; do
      run_step "backendfailover-${variant}" env FAILOVER_POLICIES="$variant" "$WD/backendfailover.sh" --iterations="$FAILOVER_ITERATIONS"
    done
  fi
fi
wants route-load && run_step route-load env RUN_DURATION="$SCALE_DURATION" "$WD/route-load.sh" "$ROUTE_LOAD_NAMESPACES" "$ROUTE_LOAD_ROUTES"
wants listenerset-load && run_step listenerset-load env RUN_DURATION="$SCALE_DURATION" "$WD/listenerset-load.sh" "$LISTENERSET_NAMESPACES" "$LISTENERSETS"

if wants traffic; then
  IFS=',' read -r -a connections <<< "$TRAFFIC_CONNECTIONS"
  for connection in "${connections[@]}"; do
    run_step "traffic-c${connection}" "$WD/traffic.sh" -d "$TRAFFIC_DURATION" -q 0 -c "$connection" -p "$TRAFFIC_PAYLOAD"
  done
fi

python3 "${WD}/../scripts/summarize_results.py" "$RESULTS_DIR" --status "$STATUS_FILE" --output "${RESULTS_DIR}/summary-${RUN_ID}.md"
echo "status: ${STATUS_FILE}"
echo "summary: ${RESULTS_DIR}/summary-${RUN_ID}.md"
