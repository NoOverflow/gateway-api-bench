#!/bin/bash
# set -e
WD=$(dirname "$0")
WD=$(cd "$WD"; pwd)
source "$WD/common.sh"

# Implementation-specific failover policies are NOT part of the baseline test:
# every gateway is measured with its out-of-the-box behaviour. Set
# FAILOVER_POLICIES=<dir under tests/backendfailover/policies> (e.g. "outlier"
# or "active") to run a variant with those manifests applied for the duration
# of the test. The baseline always removes any leftover variant policies first
# so a previous variant cannot leak into the comparison.
POLICY_ROOT="${WD}/backendfailover/policies"
for dir in "${POLICY_ROOT}"/*/; do
  kubectl delete -f "$dir" --ignore-not-found >/dev/null 2>&1 || true
done
if [[ -n "${FAILOVER_POLICIES:-}" ]]; then
  if [[ ! -d "${POLICY_ROOT}/${FAILOVER_POLICIES}" ]]; then
    echo "unknown FAILOVER_POLICIES variant: ${FAILOVER_POLICIES}" >&2
    exit 1
  fi
  echo "applying failover policy variant: ${FAILOVER_POLICIES}" >&2
  # Keep variant samples in a separate result file from the baseline.
  RESULT_RUN_ID="${RESULT_RUN_ID}-${FAILOVER_POLICIES}"
  kubectl apply -f "${POLICY_ROOT}/${FAILOVER_POLICIES}"
  trap 'kubectl delete -f "${POLICY_ROOT}/${FAILOVER_POLICIES}" --ignore-not-found >/dev/null 2>&1 || true' EXIT
fi

# Run one gateway at a time so each is measured in isolation. Probing every
# gateway concurrently starves the others on a CPU-constrained node and skews the
# failover results. Set COMBINED=1 to probe all gateways in a single run instead.
if [[ "${COMBINED:-}" == "1" ]]; then
  run-in-cluster "${WD}/backendfailover" --gateways="$(join_by ',' "${gateways[@]}")" `log-flag` "$@"
else
  for gw in "${gateways[@]}"; do
    run-in-cluster "${WD}/backendfailover" --gateways="$gw" `log-flag` "$@"
  done
fi
