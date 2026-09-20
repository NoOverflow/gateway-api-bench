
WD=$(dirname "${BASH_SOURCE[0]}")
WD=$(cd "$WD"; pwd)

# Go is installed under /usr/local/go/bin on this host, but that directory is
# absent from non-interactive PATHs. Allow an explicit override and otherwise
# fall back to the standard installation location.
GO_BIN="${GO_BIN:-$(command -v go 2>/dev/null || true)}"
if [[ -z "$GO_BIN" && -x /usr/local/go/bin/go ]]; then
  GO_BIN=/usr/local/go/bin/go
fi
if [[ -z "$GO_BIN" ]]; then
  echo "go is required to build benchmark binaries; set GO_BIN or add go to PATH" >&2
  return 1 2>/dev/null || exit 1
fi

RESULTS_DIR="${RESULTS_DIR:-${WD}/../results}"
# One script invocation may run gateways sequentially. Keep their samples in
# one result file; callers can set this explicitly to correlate separate runs.
RESULT_RUN_ID="${RESULT_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM}"

PILOT_LOAD_BIN="${PILOT_LOAD_BIN:-$(command -v pilot-load 2>/dev/null || true)}"
if [[ -z "$PILOT_LOAD_BIN" && -x "$HOME/go/bin/pilot-load" ]]; then
  PILOT_LOAD_BIN="$HOME/go/bin/pilot-load"
fi

# Use the GATEWAYS environment variable. If unset, fall back to the defaults.
if [[ -n "${GATEWAYS:-}" ]]; then
  IFS=',' read -r -a gateways <<< "$GATEWAYS"
else
  gateways=(agentgateway/agentgateway  envoy/envoy-gateway istio/istio nginx/nginx haproxy/haproxy)
fi

function gw-address() {
  local name;
  local namespace;
  if [[ "$1" == */* ]]; then
    namespace="$(<<<"$1" cut -d/ -f1)"
    name="$(<<<"$1" cut -d/ -f2)"
  elif [[ "${2:-}" != "" ]]; then
    namespace="$1"
    name="$2"
  else
    name="$1"
  fi

  kubectl get gateways.gateway.networking.k8s.io -ojsonpath='{.status.addresses[0].value}' "${namespace+--namespace=$namespace}" "$name"
}

function svc-address() {
  local name;
  local namespace;
  if [[ "$1" == *"/"* ]]; then
    namespace="$(<<<"$1" cut -d/ -f1)"
    name="$(<<<"$1" cut -d/ -f2)"
  elif [[ "${2:-}" != "" ]]; then
    namespace="$1"
    name="$2"
  else
    name="$1"
  fi

  kubectl  get service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' ${namespace+--namespace=$namespace} "$name"
}

function join_by { local IFS="$1"; shift; echo "$*"; }

# Map each gateway (namespace/name) to the Service (namespace/name) that fronts
# its HTTP (port 80) listener. On CRC/OpenShift Local the node's NodePorts are
# not directly reachable from this machine (gvisor-tap-vsock user networking), so
# the load tests run *inside* the cluster (see run-in-cluster) and dial the
# gateways by their in-cluster Service DNS on port 80 instead of the gateway
# status address (which, for envoy/haproxy, is the node IP and only serves the
# gateway on a NodePort, not port 80).
declare -A GW_SERVICE=(
  ["agentgateway/agentgateway"]="agentgateway/agentgateway"
  ["envoy/envoy-gateway"]="envoy/envoy-gateway"
  ["istio/istio"]="istio/istio-istio"
  ["nginx/nginx"]="nginx/nginx-nginx"
  ["haproxy/haproxy"]="haproxy-system/haproxy-haproxy-unified-gateway"
)

# in-cluster-address <gateway ns/name> -> echoes "<svc>.<ns>.svc:80"
function in-cluster-address() {
  local svc="${GW_SERVICE[$1]:-}"
  [[ -z "$svc" ]] && return 0
  local sns="${svc%/*}" sname="${svc#*/}"
  echo "${sname}.${sns}.svc:80"
}

# Build GATEWAY_ADDRESS_OVERRIDES (consumed by the Go tests via internal/gwaddr)
# mapping each gateway to its in-cluster Service address. Gateways without a
# known Service are skipped and fall back to the status address.
function build-address-overrides() {
  local pairs=() gw addr
  for gw in "${gateways[@]}"; do
    addr="$(in-cluster-address "$gw")"
    [[ -n "$addr" ]] && pairs+=("${gw}=${addr}")
  done
  join_by , "${pairs[@]}"
}

export GATEWAY_ADDRESS_OVERRIDES="${GATEWAY_ADDRESS_OVERRIDES:-$(build-address-overrides)}"

# --- in-cluster test runner ------------------------------------------------
# The gateways are only reachable from inside the cluster, so the Go load tests
# are built as a static binary and executed in a long-lived runner Pod. The Pod
# runs under a cluster-admin ServiceAccount; the pilot-load kube client falls
# back to in-cluster config when no kubeconfig file is present, and kubectl
# (copied into the Pod) is used by tests that shell out (e.g. backendfailover).
BENCH_NS="${BENCH_NS:-default}"
BENCH_SA="${BENCH_SA:-bench-runner}"
BENCH_POD="${BENCH_POD:-bench-runner}"
BENCH_IMAGE="${BENCH_IMAGE:-registry.access.redhat.com/ubi9/ubi:latest}"

function ensure-runner() {
  kubectl get sa "$BENCH_SA" -n "$BENCH_NS" >/dev/null 2>&1 || \
    kubectl create sa "$BENCH_SA" -n "$BENCH_NS"
  kubectl get clusterrolebinding "$BENCH_SA" >/dev/null 2>&1 || \
    kubectl create clusterrolebinding "$BENCH_SA" --clusterrole=cluster-admin \
      --serviceaccount="$BENCH_NS:$BENCH_SA"
  if ! kubectl get pod "$BENCH_POD" -n "$BENCH_NS" >/dev/null 2>&1; then
    kubectl run "$BENCH_POD" -n "$BENCH_NS" --image="$BENCH_IMAGE" \
      --overrides="{\"spec\":{\"serviceAccountName\":\"$BENCH_SA\"}}" \
      --command -- sleep infinity
  fi
  kubectl wait --for=condition=Ready "pod/$BENCH_POD" -n "$BENCH_NS" --timeout=180s
  # The Pod's container filesystem is ephemeral, so the kubectl binary is lost
  # whenever the Pod restarts (e.g. after a crc stop/start). (Re)install it
  # whenever it is missing rather than only when the Pod is first created.
  if ! kubectl exec -n "$BENCH_NS" "$BENCH_POD" -- test -x /usr/local/bin/kubectl 2>/dev/null; then
    kubectl cp "$(command -v kubectl)" "$BENCH_NS/$BENCH_POD:/usr/local/bin/kubectl"
    kubectl exec -n "$BENCH_NS" "$BENCH_POD" -- chmod +x /usr/local/bin/kubectl
  fi
}

# run-in-cluster <test-dir> [args...] : build the test in <test-dir> and run it
# inside the runner Pod with the gateway address overrides set.
function run-in-cluster() {
  local dir="$1"; shift
  local name; name="$(basename "$dir")"
  local bin="/tmp/${name}"
  local run_id; run_id="$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
  local pod_output="/tmp/${name}-${run_id}.csv"
  local host_output="${RESULTS_DIR}/${name}-${RESULT_RUN_ID}.csv"
  local staged_output="${RESULTS_DIR}/.${name}-${run_id}.csv"
  local run_start; run_start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "building ${name}..." >&2
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 "$GO_BIN" build -o "$bin" "$dir"
  ensure-runner
  kubectl cp "$bin" "$BENCH_NS/$BENCH_POD:/usr/local/bin/${name}"
  kubectl exec -n "$BENCH_NS" "$BENCH_POD" -- chmod +x "/usr/local/bin/${name}"
  mkdir -p "$RESULTS_DIR"
  local rc=0
  kubectl exec -i -n "$BENCH_NS" "$BENCH_POD" -- \
    env GATEWAY_ADDRESS_OVERRIDES="$GATEWAY_ADDRESS_OVERRIDES" \
    "/usr/local/bin/${name}" "$@" "--output=${pod_output}" || rc=$?
  if kubectl cp "$BENCH_NS/$BENCH_POD:${pod_output}" "$staged_output" >/dev/null 2>&1; then
    if [[ -e "$host_output" ]]; then
      awk 'NR > 1 { print }' "$staged_output" >>"$host_output"
      rm -f "$staged_output"
    else
      mv "$staged_output" "$host_output"
    fi
    echo "static CSV: ${host_output}" >&2
  else
    echo "warning: ${name} did not produce static CSV output" >&2
  fi
  if kubectl get service victoria-logs -n monitoring >/dev/null 2>&1; then
    local logs_output="${RESULTS_DIR}/${name}-${RESULT_RUN_ID}-victoria.jsonl"
    local staged_logs="${RESULTS_DIR}/.${name}-${run_id}-victoria.jsonl"
    local attempt
    for attempt in 1 2 3; do
      kubectl exec -n "$BENCH_NS" "$BENCH_POD" -- \
        curl -fsSG http://victoria-logs.monitoring.svc:9428/select/logsql/query \
        --data-urlencode "query=test:${name}" \
        --data-urlencode "start=${run_start}" >"$staged_logs" && [[ -s "$staged_logs" ]] && break
      sleep 2
    done
    if [[ -s "$staged_logs" ]]; then
      cat "$staged_logs" >>"$logs_output"
      rm -f "$staged_logs"
      echo "VictoriaLogs export: ${logs_output}" >&2
    else
      rm -f "$staged_logs"
      echo "VictoriaLogs has no samples for ${name}" >&2
    fi
  fi
  return "$rc"
}

function log-flag() {
  # The tests run inside the cluster (see run-in-cluster), so report to
  # victoria-logs via its in-cluster Service DNS rather than a LoadBalancer IP.
  if kubectl get service victoria-logs -n monitoring >/dev/null 2>&1; then
    echo "--victoria=http://victoria-logs.monitoring.svc:9428"
  fi
}

# Export only gateway control/data-plane resources for the scale tests. The raw
# Prometheus range responses are retained alongside a normalized CSV suitable
# for plotting and comparing implementations.
# export-prometheus-snapshot <test> <start> <end> [target-gateway]
# When the scale tests run one gateway at a time, pass the gateway under load
# (namespace/name) so the CSV records which implementation the routes targeted;
# the other implementations' usage is then the cost of processing resources
# that are not aimed at them.
function export-prometheus-snapshot() {
  local test="$1"
  local start="$2"
  local end="$3"
  local target="${4:-}"
  mkdir -p "$RESULTS_DIR"
  ensure-runner
  local base="${RESULTS_DIR}/${test}-${RESULT_RUN_ID}"
  local target_args=()
  if [[ -n "$target" ]]; then
    base="${base}-${target#*/}"
    target_args=(--target "${target#*/}")
  fi
  local namespaces='agentgateway|agentgateway-system|envoy|envoy-gateway-system|istio|istio-system|nginx|nginx-system|haproxy-system'
  kubectl exec -n "$BENCH_NS" "$BENCH_POD" -- \
    curl -fsSG http://prometheus.monitoring.svc:9090/api/v1/query_range \
    --data-urlencode "query=sum by (namespace,pod,container) (rate(container_cpu_usage_seconds_total{namespace=~\"${namespaces}\",container!=\"\",container!=\"POD\"}[1m]))" \
    --data-urlencode "start=${start}" --data-urlencode "end=${end}" --data-urlencode 'step=5s' \
    >"${base}-cpu.json"
  kubectl exec -n "$BENCH_NS" "$BENCH_POD" -- \
    curl -fsSG http://prometheus.monitoring.svc:9090/api/v1/query_range \
    --data-urlencode "query=sum by (namespace,pod,container) (container_memory_working_set_bytes{namespace=~\"${namespaces}\",container!=\"\",container!=\"POD\"})" \
    --data-urlencode "start=${start}" --data-urlencode "end=${end}" --data-urlencode 'step=5s' \
    >"${base}-memory.json"
  kubectl exec -n "$BENCH_NS" "$BENCH_POD" -- \
    curl -fsSG http://prometheus.monitoring.svc:9090/api/v1/query_range \
    --data-urlencode "query=sum by (namespace,pod) (rate(container_network_transmit_bytes_total{namespace=~\"${namespaces}\",container=\"POD\"}[1m]))" \
    --data-urlencode "start=${start}" --data-urlencode "end=${end}" --data-urlencode 'step=5s' \
    >"${base}-network.json"
  python3 "${WD}/../scripts/metrics_to_csv.py" \
    --cpu "${base}-cpu.json" --memory "${base}-memory.json" --network "${base}-network.json" \
    --output "${base}-resources.csv" "${target_args[@]}"
  echo "gateway resource CSV: ${base}-resources.csv" >&2
}
