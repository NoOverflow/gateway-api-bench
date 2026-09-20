#!/bin/bash

WD=$(dirname "$0")
WD=$(cd "$WD"; pwd)
source "$WD/common.sh"

namespaces="${1:-10}"
routes="${2:-100}"

if [[ -z "$PILOT_LOAD_BIN" ]]; then
  echo "pilot-load is required; set PILOT_LOAD_BIN or add it to PATH" >&2
  exit 1
fi

mesh_namespaces() {
  if (( namespaces <= 1 )); then
    echo "mesh"
  else
    local r
    for (( r = 0; r < namespaces; r++ )); do echo "mesh-0-${r}"; done
  fi
}

if command -v oc >/dev/null 2>&1 && oc get scc anyuid >/dev/null 2>&1; then
  echo "OpenShift detected: granting anyuid to pilot-load namespaces' default SA..." >&2
  for ns in $(mesh_namespaces); do
    oc adm policy add-scc-to-user anyuid "system:serviceaccount:${ns}:default" >/dev/null 2>&1 || true
  done
  cleanup() {
    echo "removing anyuid grants..." >&2
    for ns in $(mesh_namespaces); do
      oc adm policy remove-scc-from-user anyuid "system:serviceaccount:${ns}:default" >/dev/null 2>&1 || true
    done
  }
  trap cleanup EXIT
fi

run_pilot_load() {
  if [[ -n "${RUN_DURATION:-}" ]]; then
    timeout --foreground "$RUN_DURATION" "$PILOT_LOAD_BIN" cluster --config -
    local rc=$?
    [[ $rc -eq 124 ]] && return 0
    return "$rc"
  fi
  "$PILOT_LOAD_BIN" cluster --config -
}

# Wait until pilot-load has torn down the namespaces of the previous run so the
# next run starts from a clean cluster instead of racing an async delete.
wait_for_teardown() {
  local ns
  for ns in $(mesh_namespaces); do
    kubectl wait --for=delete "namespace/${ns}" --timeout=180s >/dev/null 2>&1 || \
      kubectl delete namespace "$ns" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true
  done
}

# run_load <gateway>... : generate the routes (all attached to the given
# gateways) for RUN_DURATION, then snapshot the gateways' resource usage.
run_load() {
  local target="${1:-}"
  local gateway_list="" gw
  for gw in "$@"; do
    gateway_list+="          - ${gw}"$'\n'
  done
  wait_for_teardown
  local run_start run_end
  run_start="$(date +%s)"
  cat <<EOF | run_pilot_load
jitter:
  workloads: "2s"
  config: "1s"
gracePeriod: 500ms
stableNames: true
namespaces:
  - name: mesh
    replicas: ${namespaces}
    applications:
    - name: app
      replicas: ${routes}
      pods: 1
      type: plain
      configs:
      - name: httproute
        config:
          gateways:
${gateway_list}
nodes:
- name: node
  count: 20
EOF
  run_end="$(date +%s)"
  # pilot-load is intentionally long-running for scale tests. When it is stopped,
  # capture the resource state that it created for offline graphs.
  if (( $# == 1 )); then
    export-prometheus-snapshot route-load "$run_start" "$run_end" "$target"
  else
    export-prometheus-snapshot route-load "$run_start" "$run_end"
  fi
}

# Default to loading one gateway at a time so implementations do not compete
# for the node's CPU while they are measured (the resource snapshot still
# covers every implementation, so the cost of processing routes aimed at
# another gateway remains visible). Set COMBINED=1 to attach every route to all
# gateways in a single run, as the original report did.
if [[ "${COMBINED:-}" == "1" ]]; then
  run_load "${gateways[@]}"
else
  for gw in "${gateways[@]}"; do
    echo "route-load: targeting ${gw}" >&2
    run_load "$gw"
  done
fi
wait_for_teardown
