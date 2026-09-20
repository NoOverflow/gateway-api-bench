#!/usr/bin/env python3
"""Normalize gateway-only Prometheus range responses into a long-form CSV."""

import argparse
import csv
import json
from collections import defaultdict


NAMESPACES = {
    "agentgateway": ("agentgateway", "data-plane"),
    "agentgateway-system": ("agentgateway", "control-plane"),
    "envoy": ("envoy-gateway", "data-plane"),
    "envoy-gateway-system": ("envoy-gateway", "control-plane"),
    "istio": ("istio", "data-plane"),
    "istio-system": ("istio", "control-plane"),
    "nginx": ("nginx", "data-plane"),
    "nginx-system": ("nginx", "control-plane"),
    # HAProxy's chart combines its controller and proxy in one workload.
    "haproxy-system": ("haproxy", "combined"),
}


def load_metric(path, metric, values):
    for series in json.load(open(path))["data"]["result"]:
        target = NAMESPACES.get(series["metric"].get("namespace"))
        if target is None:
            continue
        gateway, plane = target
        for timestamp, value in series["values"]:
            values[(float(timestamp), gateway, plane, metric)] += float(value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cpu", required=True)
    parser.add_argument("--memory", required=True)
    parser.add_argument("--network", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--target", default="", help="gateway the load targeted (blank when all gateways were loaded at once)")
    args = parser.parse_args()
    values = defaultdict(float)
    load_metric(args.cpu, "cpu_cores", values)
    load_metric(args.memory, "memory_bytes", values)
    load_metric(args.network, "network_tx_bytes_per_second", values)
    with open(args.output, "w", newline="") as output:
        writer = csv.writer(output)
        writer.writerow(("timestamp_unix_seconds", "gateway", "plane", "metric", "value", "target"))
        for key in sorted(values):
            writer.writerow((*key, values[key], args.target))


if __name__ == "__main__":
    main()
