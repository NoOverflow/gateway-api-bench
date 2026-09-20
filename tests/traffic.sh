#!/bin/bash
set -euo pipefail

WD=$(dirname "$0")
WD=$(cd "$WD"; pwd)
source "$WD/common.sh"


cat <<EOF | kubectl apply -f - --server-side=true
apiVersion: apps/v1
kind: Deployment
metadata:
  name: traffic-backend
  namespace: default
spec:
  selector:
    matchLabels:
      app: traffic-backend
  template:
    metadata:
      labels:
        app: traffic-backend
    spec:
      containers:
      - name: backend
        image: howardjohn/hyper-server
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
---
apiVersion: v1
kind: Service
metadata:
  name: traffic-backend
  namespace: default
spec:
  selector:
    app: traffic-backend
  ports:
  - name: http
    port: 80
    targetPort: 8080
EOF
kubectl rollout status deployment traffic-backend -n default --timeout=90s

targets=()
for gw in "${gateways[@]}"; do
  name="$(<<<"$gw" cut -d/ -f 2)"
  namespace="$(<<<"$gw" cut -d/ -f 1)"
  address="$(in-cluster-address "$gw")"
  if [[ -z "$address" ]]; then
    echo "no in-cluster Service mapping for gateway $gw" >&2
    exit 1
  fi
  targets+=("http://${address}#$name")
  cat <<EOF | kubectl apply -f - --server-side=true
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: $name
  namespace: default
spec:
  parentRefs:
  - name: $name
    namespace: $namespace
  rules:
  - backendRefs:
    - name: traffic-backend
      port: 80
EOF
done

# A benchmark must not include first-route propagation. benchtool aborts a
# target after an initial 503, which otherwise biases the first gateway run.
ensure-runner
for target in "${targets[@]}"; do
  endpoint="${target%#*}"
  ready=0
  for (( attempt = 0; attempt < 120; attempt++ )); do
    if kubectl exec -n "$BENCH_NS" "$BENCH_POD" -- curl -fsS --connect-timeout 2 --max-time 5 "$endpoint" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ "$ready" -ne 1 ]]; then
    echo "gateway ${target##*#} did not become ready within 120 seconds" >&2
    exit 1
  fi
done

mkdir -p "$RESULTS_DIR"
run_id="$(date -u +%Y%m%dt%H%M%sz)-$RANDOM"
output="${RESULTS_DIR}/traffic-${run_id}.csv"
raw_output="${RESULTS_DIR}/traffic-${run_id}.log"
failures="${RESULTS_DIR}/traffic-${run_id}-failures.csv"

# Run one target per Pod. benchtool continues after an individual target fails
# and reuses its last successful table row, so batching targets can turn a 503
# into fabricated throughput for a different gateway.
printf 'destination,client,qps,connections,duration_seconds,payload_bytes,success,throughput,p50,p90,p99\n' >"$output"
printf 'destination,reason\n' >"$failures"
failed=0
for target in "${targets[@]}"; do
  destination="${target##*#}"
  target_log="${RESULTS_DIR}/traffic-${run_id}-${destination}.log"
  args_json="$(jq -cn --args '$ARGS.positional' -- "$@" "$target")"
  pod_name="traffic-${RANDOM}-${destination}"
  if ! kubectl run "$pod_name" -n "$BENCH_NS" --rm -i --restart=Never \
    --image=howardjohn/benchtool \
    --overrides="{\"spec\":{\"volumes\":[{\"name\":\"results\",\"emptyDir\":{}}],\"containers\":[{\"name\":\"$pod_name\",\"image\":\"howardjohn/benchtool\",\"command\":[\"/usr/bin/benchmark\"],\"args\":${args_json},\"volumeMounts\":[{\"name\":\"results\",\"mountPath\":\"/tmp/results\"}]}]}}" | tee "$target_log"; then
    printf '%s,kubectl run failed\n' "$destination" >>"$failures"
    failed=1
  elif grep -qE 'COMMAND FAILED|Aborting because of error' "$target_log"; then
    printf '%s,benchmark returned HTTP errors\n' "$destination" >>"$failures"
    failed=1
  elif ! awk '$2 ~ /^(fortio|hey|oha|nighthawk|wrk)$/ && $7 ~ /^[0-9.]+%?$/ { print $1 "," $2 "," $3 "," $4 "," $5 "," $6 "," $7 "," $8 "," $9 "," $10 "," $11; found=1 } END { exit !found }' "$target_log" >>"$output"; then
    printf '%s,no parseable result row\n' "$destination" >>"$failures"
    failed=1
  fi
  cat "$target_log" >>"$raw_output"
done
if [[ "$failed" -eq 1 ]]; then
  echo "one or more traffic targets failed; see ${failures}" >&2
  exit 1
fi
rm -f "$failures"
echo "static CSV: ${output}" >&2
