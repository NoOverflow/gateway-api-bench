#!/bin/bash
set -e
WD=$(dirname "$0")
WD=$(cd "$WD"; pwd)
source "$WD/common.sh"


# Default to one gateway at a time so each is measured in isolation (probing all
# gateways concurrently starves them on a CPU-constrained node). Set COMBINED=1
# to probe all gateways in a single run instead.
if [[ "${COMBINED:-}" == "1" ]]; then
  run-in-cluster "${WD}/probe" --gateways="$(join_by ',' "${gateways[@]}")" `log-flag` "$@"
else
  for gw in "${gateways[@]}"; do
    run-in-cluster "${WD}/probe" --gateways="$gw" `log-flag` "$@"
  done
fi
