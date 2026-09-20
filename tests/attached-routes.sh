#!/bin/bash
WD=$(dirname "$0")
WD=$(cd "$WD"; pwd)
source "$WD/common.sh"

# Default to one gateway at a time (sequential). Set COMBINED=1 to run all
# gateways in a single invocation instead. Runs in-cluster (like the other
# tests) so the in-cluster victoria-logs address in log-flag resolves.
# NOTE: this test requires each gateway to start with 0 attached routes, so run
# it after clearing routes created by other benchmark scripts.
kubectl delete namespace mesh --ignore-not-found --wait=true --timeout=120s
kubectl delete httproute --all --all-namespaces --ignore-not-found
kubectl wait --for=delete httproute --all --all-namespaces --timeout=120s 2>/dev/null || true
# Route creation is rate limited by the generator, so the attach timings are
# similar across implementations; the resource snapshot captures how much
# work each controller does to process the same status updates.
if [[ "${COMBINED:-}" == "1" ]]; then
  run_start="$(date +%s)"
  run-in-cluster "${WD}/attachedroutes" --gateways="$(join_by ',' "${gateways[@]}")" `log-flag` "$@"
  export-prometheus-snapshot attached-routes "$run_start" "$(date +%s)"
else
  for gw in "${gateways[@]}"; do
    run_start="$(date +%s)"
    run-in-cluster "${WD}/attachedroutes" --gateways="$gw" `log-flag` "$@"
    export-prometheus-snapshot attached-routes "$run_start" "$(date +%s)" "$gw"
    # pilot-load deletes its mesh namespace asynchronously. Waiting prevents
    # the next gateway run from racing an old Namespace status update.
    kubectl wait --for=delete namespace/mesh --timeout=90s 2>/dev/null || true
  done
fi
