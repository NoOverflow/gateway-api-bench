#!/usr/bin/env python3
"""Create an outlier-first Markdown summary from benchmark result CSVs."""

import argparse
import csv
import re
import statistics
from collections import defaultdict
from pathlib import Path


GATEWAYS = ["agentgateway", "envoy-gateway", "istio", "nginx", "haproxy"]


def short(gateway):
    return gateway.split("/")[-1]


def ordered(names):
    names = set(names)
    return [g for g in GATEWAYS if g in names] + sorted(n for n in names if n not in GATEWAYS)


def rows(results_dir, prefix, exclude=None):
    for path in sorted(results_dir.glob(f"{prefix}-*.csv")):
        if exclude and re.search(exclude, path.name):
            continue
        with path.open(newline="") as source:
            for row in csv.DictReader(source):
                row["_file"] = path.name
                yield row


def median(values):
    return statistics.median(values) if values else 0


def percentile(values, p):
    if not values:
        return 0
    values = sorted(values)
    return values[min(len(values) - 1, int(p * (len(values) - 1)))]


def traffic_summary(results_dir):
    points = defaultdict(list)
    for row in rows(results_dir, "traffic", exclude=r"failures"):
        try:
            points[(int(row["connections"]), row["destination"])].append(
                (float(row["throughput"].removesuffix("qps")), float(row["p50"].removesuffix("ms")), float(row["p99"].removesuffix("ms")))
            )
        except (KeyError, ValueError):
            continue
    lines = ["## Traffic", "", "| Connections | Gateway | QPS | p50 (ms) | p99 (ms) |", "|---:|---|---:|---:|---:|"]
    outliers = []
    for connection in sorted({key[0] for key in points}):
        samples = {gateway: median([v[0] for v in values]) for (current, gateway), values in points.items() if current == connection}
        baseline = median(list(samples.values()))
        for gateway in ordered(samples):
            value = samples[gateway]
            p50 = median([v[1] for v in points[(connection, gateway)]])
            p99 = median([v[2] for v in points[(connection, gateway)]])
            lines.append(f"| {connection} | {gateway} | {value:,.0f} | {p50:.2f} | {p99:.2f} |")
            if baseline and (value < baseline * 0.5 or value > baseline * 2):
                direction = "below" if value < baseline else "above"
                outliers.append(f"traffic c={connection}: **{gateway}** is {value / baseline:.2f}x {direction} the median")
    return lines, outliers


def attached_summary(results_dir):
    samples = defaultdict(list)
    for row in rows(results_dir, "attachedroutes", exclude=r"victoria"):
        samples[short(row["gateway"])].append((int(row["timestamp_unix_nano"]) / 1e9, int(row["attached_routes"])))
    if not samples:
        return []
    target = max(v for s in samples.values() for _, v in s)
    lines = ["## Attached Routes", "", f"| Gateway | Status updates | Seconds until attachedRoutes={target} | Seconds from peak back to 0 |", "|---|---:|---:|---:|"]
    for gateway in ordered(samples):
        s = sorted(samples[gateway])
        t0 = s[0][0]
        hit = next((t - t0 for t, v in s if v >= target), None)
        peak_last = max((t for t, v in s if v >= target), default=None)
        zero = next((t for t, v in s if peak_last is not None and t > peak_last and v == 0), None)
        lines.append(
            f"| {gateway} | {len(s)} | {'%.1f' % hit if hit is not None else 'never'} | {'%.1f' % (zero - peak_last) if zero is not None else 'never'} |"
        )
    return lines


def probe_summary(results_dir):
    samples = defaultdict(list)
    retries = defaultdict(int)
    for row in rows(results_dir, "probe", exclude=r"victoria"):
        samples[short(row["gateway"])].append(float(row["latency_microseconds"]) / 1000)
        retries[short(row["gateway"])] += int(row["errors"])
    lines = ["## Route Propagation", "", "| Gateway | Routes | Median latency (ms) | p99 (ms) | Max (ms) | Error responses |", "|---|---:|---:|---:|---:|---:|"]
    for gateway in ordered(samples):
        s = samples[gateway]
        lines.append(f"| {gateway} | {len(s)} | {median(s):.1f} | {percentile(s, 0.99):.1f} | {max(s):.1f} | {retries[gateway]} |")
    return lines


def routechange_summary(results_dir):
    outcomes = defaultdict(lambda: [0, 0, defaultdict(int)])
    for row in rows(results_dir, "routechange"):
        gw = short(row["gateway"])
        outcomes[gw][0] += 1
        if row["success"] != "true":
            outcomes[gw][1] += 1
            outcomes[gw][2][row["status_code"]] += 1
    lines = ["## Route Changes", "", "| Gateway | Requests | Errors | Error rate | Error codes |", "|---|---:|---:|---:|---|"]
    for gateway in ordered(outcomes):
        total, errors, codes = outcomes[gateway]
        code_text = ", ".join(f"{c}×{n}" for c, n in sorted(codes.items())) or "-"
        lines.append(f"| {gateway} | {total} | {errors} | {errors / total:.2%} | {code_text} |")
    return lines


def failover_summary(results_dir):
    variants = defaultdict(lambda: defaultdict(lambda: [0, 0, 0, 0]))
    for row in rows(results_dir, "backendfailover", exclude=r"victoria"):
        m = re.match(r"backendfailover-\d{8}T\d{6}Z-\d+(?:-(?P<variant>[a-z0-9-]+))?\.csv$", row["_file"])
        variant = (m.group("variant") if m else None) or "baseline"
        stats = variants[variant][short(row["gateway"])]
        stats[0] += 1
        stats[1] += row["success"] != "true"
        if row.get("backend_phase") == "unhealthy" and row.get("backend") == "backend-unhealthy":
            stats[2] += 1
            stats[3] += row["success"] != "true"
    lines = []
    for variant in ["baseline"] + sorted(v for v in variants if v != "baseline"):
        if variant not in variants:
            continue
        lines += [f"## Backend Failover ({variant})", "", "| Gateway | Requests | Failed | Sent to unhealthy backend while unhealthy | of which failed |", "|---|---:|---:|---:|---:|"]
        for gateway in ordered(variants[variant]):
            total, failed, unhealthy_hits, unhealthy_failed = variants[variant][gateway]
            lines.append(f"| {gateway} | {total} | {failed} | {unhealthy_hits} | {unhealthy_failed} |")
        lines.append("")
    return lines


def scale_summary(results_dir, test, title):
    runs = defaultdict(list)
    for path in sorted(results_dir.glob(f"{test}-*-resources.csv")):
        with path.open(newline="") as source:
            for row in csv.DictReader(source):
                target = row.get("target") or ""
                if not target:
                    m = re.match(rf"{test}-\d{{8}}T\d{{6}}Z-\d+-(?P<gw>[a-z-]+)-resources\.csv$", path.name)
                    target = m.group("gw") if m else ""
                runs[target].append(row)
    if not runs:
        return []
    sequential = "" not in runs
    lines = [f"## {title}", ""]
    lines.append("Each gateway loaded in its own run; other rows show the cost of processing routes aimed at another gateway." if sequential else "All gateways loaded at once.")
    lines += ["", "| Gateway | Plane | Mean CPU (cores) | Peak CPU | Mean memory (MB) | Peak memory | Mean net TX (KB/s) |", "|---|---|---:|---:|---:|---:|---:|"]
    gateways = ordered(g for g in (runs if sequential else {r["gateway"] for r in runs[""]}) if g)
    for gateway in gateways:
        own = runs[gateway] if sequential else runs[""]
        for plane in ["control-plane", "data-plane", "combined"]:
            values = defaultdict(list)
            for r in own:
                if r["gateway"] == gateway and r["plane"] == plane:
                    values[r["metric"]].append(float(r["value"]))
            if not values:
                continue
            cpu = values["cpu_cores"]
            mem = [v / 1e6 for v in values["memory_bytes"]]
            net = [v / 1e3 for v in values["network_tx_bytes_per_second"]]
            lines.append(f"| {gateway} | {plane} | {statistics.mean(cpu):.3f} | {max(cpu):.3f} | {statistics.mean(mem):.0f} | {max(mem):.0f} | {statistics.mean(net):.1f} |")
    if sequential:
        lines += ["", "Bystander cost (mean CPU cores, all planes, while another gateway's routes were generated):", "", "| Gateway | Own run | Other gateways' runs |", "|---|---:|---:|"]
        for gateway in gateways:
            def mean_cpu(rs):
                per_ts = defaultdict(float)
                for r in rs:
                    if r["gateway"] == gateway and r["metric"] == "cpu_cores":
                        per_ts[r["timestamp_unix_seconds"]] += float(r["value"])
                return statistics.mean(per_ts.values()) if per_ts else 0.0
            others = [mean_cpu(runs[t]) for t in runs if t and t != gateway]
            lines.append(f"| {gateway} | {mean_cpu(runs[gateway]):.3f} | {statistics.mean(others) if others else 0:.3f} |")
    return lines


def status_summary(path):
    if not path.exists():
        return []
    with path.open(newline="") as source:
        status = list(csv.DictReader(source))
    lines = ["## Test Status", "", "| Test | Status | Duration (s) |", "|---|---|---:|"]
    for row in status:
        lines.append(f"| {row['test']} | {row['status']} | {row['duration_seconds']} |")
    return lines


def versions_summary(results_dir):
    lines = []
    for path in sorted(results_dir.glob("versions-*.csv")):
        lines = ["## Versions", "", "| Release | Namespace | Chart | App version |", "|---|---|---|---|"]
        with path.open() as source:
            for line in source:
                if line.startswith("#") or line.startswith("release,"):
                    continue
                parts = line.rstrip("\n").split(",")
                if len(parts) >= 4:
                    lines.append(f"| {parts[0]} | {parts[1]} | {parts[2]} | {parts[3]} |")
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results_dir", type=Path)
    parser.add_argument("--status", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    traffic, outliers = traffic_summary(args.results_dir)
    document = ["# Benchmark Summary", "", *status_summary(args.status), "", *versions_summary(args.results_dir), ""]
    if outliers:
        document.extend(["## Outliers", "", *[f"- {outlier}" for outlier in outliers], ""])
    document.extend(
        [
            *attached_summary(args.results_dir),
            "",
            *probe_summary(args.results_dir),
            "",
            *routechange_summary(args.results_dir),
            "",
            *failover_summary(args.results_dir),
            "",
            *scale_summary(args.results_dir, "route-load", "Route Scale"),
            "",
            *scale_summary(args.results_dir, "listenerset-load", "ListenerSet Scale"),
            "",
            *traffic,
            "",
        ]
    )
    args.output.write_text("\n".join(document))


if __name__ == "__main__":
    main()
