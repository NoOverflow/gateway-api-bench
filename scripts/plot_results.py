#!/usr/bin/env python3
"""Render one or more charts per benchmark scenario from the raw result CSVs.

Reads every ``<test>-*.csv`` in the results directory (the current run; archived
runs live in sub-directories and are ignored) and writes PNGs to
``<results>/graphs`` (or ``--output-dir``).

Charts:
  attached-routes.png          attachedRoutes status over time, per gateway
  attached-routes-summary.png  time until all routes were reported attached
  probe.png                    route propagation latency per route, per gateway
  probe-summary.png            median / p99 propagation latency
  routechange.png              errors during route changes (per-gateway timeline)
  routechange-summary.png      error rate during route changes
  backendfailover[-<variant>].png   requests to the flapping backend over time
  backendfailover-summary.png  failed requests while the backend was unhealthy
  route-load.png / listenerset-load.png          CPU & memory of the gateway under load
  route-load-network.png / listenerset-load-network.png  network transmit
  route-load-bystander.png / listenerset-load-bystander.png  CPU spent on other gateways' routes
  route-load-normalized.png    normalized scalability score (report v2 formula)
  traffic-throughput.png       throughput vs connections
  traffic-latency.png          p50 / p99 latency vs connections
"""

import argparse
import csv
import re
import statistics
from collections import defaultdict
from pathlib import Path

try:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.ticker import FixedLocator, FuncFormatter, NullLocator
except ImportError as error:  # pragma: no cover
    raise SystemExit("matplotlib is required; install with: python3 -m pip install -r requirements.txt") from error


# --- palette & chrome (dataviz reference palette, light surface) -------------
GATEWAYS = ["agentgateway", "envoy-gateway", "istio", "nginx", "haproxy"]
LABELS = {
    "agentgateway": "Agentgateway",
    "envoy-gateway": "Envoy Gateway",
    "istio": "Istio",
    "nginx": "Nginx",
    "haproxy": "HAProxy",
}
# Categorical slots assigned in fixed order to the entity, never by rank.
COLORS = {
    "agentgateway": "#2a78d6",
    "envoy-gateway": "#eb6834",
    "istio": "#1baf7a",
    "nginx": "#eda100",
    "haproxy": "#e87ba4",
}
# Secondary encoding so identity never relies on hue alone.
MARKERS = {"agentgateway": "o", "envoy-gateway": "s", "istio": "^", "nginx": "D", "haproxy": "v"}
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK_2 = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
AXIS = "#c3c2b7"
CRITICAL = "#d03b3b"
BLUE_RAMP = ["#86b6ef", "#2a78d6", "#0d366b"]

plt.rcParams.update(
    {
        "font.family": "sans-serif",
        "font.size": 10,
        "axes.titlesize": 11,
        "axes.labelsize": 10,
        "figure.facecolor": SURFACE,
        "axes.facecolor": SURFACE,
        "savefig.facecolor": SURFACE,
        "text.color": INK,
        "axes.labelcolor": INK_2,
        "xtick.color": MUTED,
        "ytick.color": MUTED,
        "axes.edgecolor": AXIS,
        "legend.frameon": False,
    }
)


def short(gateway):
    """'envoy/envoy-gateway' -> 'envoy-gateway'."""
    return gateway.split("/")[-1]


def ordered(names):
    names = set(names)
    return [g for g in GATEWAYS if g in names] + sorted(n for n in names if n not in GATEWAYS)


def log_ticks(axis):
    """Readable 1-2-5 ticks on a log axis instead of bare decades."""
    lo, hi = axis.get_ylim()
    ticks = [b * 10**e for e in range(-2, 8) for b in (1, 2, 5) if lo <= b * 10**e <= hi]
    axis.yaxis.set_major_locator(FixedLocator(ticks))
    axis.yaxis.set_minor_locator(NullLocator())
    axis.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:,.10g}"))


def style(axis, ylabel=None, xlabel=None, log=False):
    axis.grid(axis="y", color=GRID, linewidth=0.8)
    axis.set_axisbelow(True)
    axis.spines[["top", "right", "left"]].set_visible(False)
    axis.spines["bottom"].set_color(AXIS)
    axis.tick_params(axis="y", length=0)
    axis.tick_params(axis="x", color=AXIS)
    if ylabel:
        axis.set_ylabel(ylabel)
    if xlabel:
        axis.set_xlabel(xlabel)
    if log:
        axis.set_yscale("log")


def heading(figure, title, subtitle=None, top=0.84):
    figure.text(0.02, 0.975, title, fontsize=14, fontweight="semibold", color=INK, va="top")
    if subtitle:
        figure.text(0.02, 0.935, subtitle, fontsize=9.5, color=INK_2, va="top")
    figure.subplots_adjust(top=top)


def legend(figure, names, where=(0.5, 0.9)):
    handles = [
        plt.Line2D([], [], color=COLORS.get(n, MUTED), marker=MARKERS.get(n, "o"), markersize=6, linewidth=2, label=LABELS.get(n, n))
        for n in names
    ]
    figure.legend(handles=handles, loc="upper center", bbox_to_anchor=where, ncol=min(5, len(names)), fontsize=9, handlelength=2.2)


def save(figure, output, name):
    figure.savefig(output / name, dpi=160, bbox_inches="tight", pad_inches=0.25)
    plt.close(figure)
    print(f"wrote {output / name}")


def read_rows(results_dir, prefix, exclude=None):
    """Rows of every ``<prefix>-*.csv`` (non-recursive), tagged with their source file."""
    rows = []
    for path in sorted(results_dir.glob(f"{prefix}-*.csv")):
        if exclude and re.search(exclude, path.name):
            continue
        with path.open(newline="") as source:
            for row in csv.DictReader(source):
                row["_file"] = path.name
                rows.append(row)
    return rows


def bars(axis, names, values, color=None, fmt="{:,.0f}", width=0.55, labels=None):
    """Thin, baseline-anchored bars with a value at the cap."""
    color = color or BLUE_RAMP[1]
    xs = range(len(names))
    rects = axis.bar(xs, values, width=width, color=color, zorder=2)
    for rect, value, name in zip(rects, values, names):
        axis.text(
            rect.get_x() + rect.get_width() / 2,
            rect.get_height(),
            fmt.format(value),
            ha="center",
            va="bottom",
            fontsize=9,
            color=INK_2,
        )
    axis.set_xticks(list(xs))
    axis.set_xticklabels(labels or [LABELS.get(n, n) for n in names])
    if values and max(values) > 0:
        axis.set_ylim(0, max(values) * 1.15)
    return rects


def grouped_bars(axis, names, series, fmt="{:,.0f}"):
    """series: list of (label, values, color)."""
    n = len(series)
    width = 0.7 / n
    xs = range(len(names))
    for i, (label, values, color) in enumerate(series):
        offs = [x - 0.35 + width * (i + 0.5) for x in xs]
        rects = axis.bar(offs, values, width=width - 0.04, color=color, label=label, zorder=2)
        for rect, value in zip(rects, values):
            axis.text(rect.get_x() + rect.get_width() / 2, rect.get_height(), fmt.format(value), ha="center", va="bottom", fontsize=8, color=INK_2)
    axis.set_xticks(list(xs))
    axis.set_xticklabels([LABELS.get(n, n) for n in names])
    # Legend sits above the plot so it never covers the tallest bar.
    axis.legend(loc="lower left", bbox_to_anchor=(0, 1.0), ncol=len(series), fontsize=9, borderaxespad=0)
    top = max((max(values) for _, values, _ in series if values), default=0)
    if top > 0 and axis.get_yscale() != "log":
        axis.set_ylim(0, top * 1.15)


# --- attached routes ----------------------------------------------------------
def plot_attached_routes(results_dir, output):
    rows = read_rows(results_dir, "attachedroutes", exclude=r"victoria")
    if not rows:
        return
    by_gw = defaultdict(list)
    for row in rows:
        by_gw[short(row["gateway"])].append((int(row["timestamp_unix_nano"]) / 1e9, int(row["attached_routes"])))
    names = ordered(by_gw)
    target = max(v for samples in by_gw.values() for _, v in samples)

    figure, axis = plt.subplots(figsize=(9, 5))
    attach_time = {}
    for name in names:
        samples = sorted(by_gw[name])
        t0 = samples[0][0]
        xs = [t - t0 for t, _ in samples]
        ys = [v for _, v in samples]
        axis.step(xs, ys, where="post", color=COLORS[name], linewidth=2, marker=MARKERS[name], markersize=4, markevery=max(1, len(xs) // 12))
        hit = next((t - t0 for t, v in samples if v >= target), None)
        if hit is not None:
            attach_time[name] = hit
    style(axis, ylabel="attachedRoutes reported in Gateway status", xlabel="seconds since the first status update")
    heading(figure, "Attached routes", f"{target} HTTPRoutes created, then deleted; each gateway measured alone")
    legend(figure, names)
    save(figure, output, "attached-routes.png")

    if attach_time:
        figure, axis = plt.subplots(figsize=(8, 4.2))
        names_hit = [n for n in names if n in attach_time]
        bars(axis, names_hit, [attach_time[n] for n in names_hit], fmt="{:.1f}s")
        style(axis, ylabel="seconds")
        heading(figure, "Time until every route was reported attached", f"first status update reporting attachedRoutes = {target}")
        save(figure, output, "attached-routes-summary.png")


def plot_attached_routes_resources(results_dir, output):
    """Controller CPU spent processing the attached-routes test (per targeted run)."""
    runs = load_resources(results_dir, "attached-routes")
    if not runs or "" in runs:
        return
    names = ordered(g for g in runs if g)
    mean_cpu, peak_cpu = {}, {}
    for name in names:
        plane = "combined" if name == "haproxy" else "control-plane"
        values = [v for _, v in series_for(runs[name], name, plane, "cpu_cores")]
        if values:
            mean_cpu[name] = statistics.mean(values)
            peak_cpu[name] = max(values)
    names = [n for n in names if n in mean_cpu]
    if not names:
        return
    figure, axis = plt.subplots(figsize=(8.5, 4.5))
    grouped_bars(axis, names, [("mean", [mean_cpu[n] for n in names], BLUE_RAMP[1]), ("peak", [peak_cpu[n] for n in names], BLUE_RAMP[0])], fmt="{:.2f}")
    style(axis, ylabel="control plane CPU cores")
    heading(figure, "Attached routes: controller CPU", "CPU used by each control plane while its 100 routes were created and removed (HAProxy: whole pod)")
    save(figure, output, "attached-routes-cpu.png")


# --- probe (route propagation) -------------------------------------------------
def plot_probe(results_dir, output):
    rows = read_rows(results_dir, "probe", exclude=r"victoria")
    if not rows:
        return
    by_gw = defaultdict(list)
    errors = defaultdict(int)
    for row in rows:
        by_gw[short(row["gateway"])].append((int(row["route"]), float(row["latency_microseconds"]) / 1000))
        errors[short(row["gateway"])] += int(row["errors"])
    names = ordered(by_gw)

    figure, axis = plt.subplots(figsize=(9, 5))
    for name in names:
        samples = sorted(by_gw[name])
        axis.plot([r for r, _ in samples], [l for _, l in samples], color=COLORS[name], linewidth=1.6, marker=MARKERS[name], markersize=3.5, alpha=0.9)
    style(axis, ylabel="ms until the route served 200 (log)", xlabel="route number", log=True)
    log_ticks(axis)
    heading(figure, "Route propagation time", "delay between creating an HTTPRoute and the gateway serving it")
    legend(figure, names)
    save(figure, output, "probe.png")

    figure, axis = plt.subplots(figsize=(8.5, 4.5))
    med = [statistics.median([l for _, l in by_gw[n]]) for n in names]
    p99 = [sorted(l for _, l in by_gw[n])[int(0.99 * (len(by_gw[n]) - 1))] for n in names]
    grouped_bars(axis, names, [("median", med, BLUE_RAMP[1]), ("p99", p99, BLUE_RAMP[0])], fmt="{:,.0f}")
    style(axis, ylabel="ms (log)", log=True)
    log_ticks(axis)
    for i, name in enumerate(names):
        if errors[name]:
            axis.text(i, axis.get_ylim()[0] * 1.15, f"{errors[name]} error responses", ha="center", fontsize=8, color=CRITICAL)
    heading(figure, "Route propagation latency", "median and p99 across routes; non-200 responses seen while waiting are counted as errors")
    save(figure, output, "probe-summary.png")


# --- route change --------------------------------------------------------------
def plot_routechange(results_dir, output):
    rows = read_rows(results_dir, "routechange")
    if not rows:
        return
    by_gw = defaultdict(list)
    for row in rows:
        by_gw[short(row["gateway"])].append((int(row["timestamp_unix_nano"]) / 1e9, row["success"] == "true", int(row["status_code"])))
    names = ordered(by_gw)

    figure, axes = plt.subplots(len(names), 1, figsize=(9, 1.5 * len(names) + 1.2), sharex=True)
    axes = list(axes) if len(names) > 1 else [axes]
    for axis, name in zip(axes, names):
        samples = sorted(by_gw[name])
        t0 = samples[0][0]
        bin_s = 0.05
        bins = defaultdict(lambda: [0, 0])
        for t, ok, _ in samples:
            b = int((t - t0) / bin_s)
            bins[b][0] += 1
            bins[b][1] += not ok
        xs = sorted(bins)
        axis.bar([x * bin_s for x in xs], [bins[x][0] for x in xs], width=bin_s * 0.85, color=GRID, zorder=2)
        axis.bar([x * bin_s for x in xs], [bins[x][1] for x in xs], width=bin_s * 0.85, color=CRITICAL, zorder=3)
        failures = sum(1 for _, ok, _ in samples if not ok)
        axis.set_title(f"{LABELS[name]} — {failures:,} failed of {len(samples):,} requests", loc="left", fontsize=10, color=INK_2)
        style(axis)
        axis.tick_params(axis="y", labelsize=8)
    axes[-1].set_xlabel("seconds since probing started (50 ms bins; gray = requests, red = non-200)")
    heading(figure, "Route changes", "continuous requests while the route is modified 10 times; each gateway measured alone", top=0.88)
    figure.tight_layout(rect=(0, 0, 1, 0.9))
    save(figure, output, "routechange.png")

    figure, axis = plt.subplots(figsize=(8, 4.2))
    rates = [100 * sum(1 for _, ok, _ in by_gw[n] if not ok) / len(by_gw[n]) for n in names]
    bars(axis, names, rates, fmt="{:.2f}%")
    style(axis, ylabel="% of requests failing")
    heading(figure, "Errors during route changes", "share of requests that did not return 200 while the route was being modified")
    save(figure, output, "routechange-summary.png")


# --- backend failover ----------------------------------------------------------
def plot_backendfailover(results_dir, output):
    paths = sorted(results_dir.glob("backendfailover-*.csv"))
    if not paths:
        return
    variants = defaultdict(list)
    for path in paths:
        if "victoria" in path.name:
            continue
        m = re.match(r"backendfailover-\d{8}T\d{6}Z-\d+(?:-(?P<variant>[a-z0-9-]+))?\.csv$", path.name)
        variant = (m.group("variant") if m else None) or "baseline"
        with path.open(newline="") as source:
            variants[variant].extend(csv.DictReader(source))

    summary = {}
    for variant, rows in variants.items():
        by_gw = defaultdict(list)
        for row in rows:
            by_gw[short(row["gateway"])].append(row)
        names = ordered(by_gw)
        figure, axes = plt.subplots(len(names), 1, figsize=(10, 1.9 * len(names) + 1.4), sharex=True)
        axes = list(axes) if len(names) > 1 else [axes]
        for axis, name in zip(axes, names):
            samples = sorted(by_gw[name], key=lambda r: int(r["timestamp_unix_nano"]))
            t0 = int(samples[0]["timestamp_unix_nano"]) / 1e9
            ok = defaultdict(int)
            bad = defaultdict(int)
            phase_bad = []
            prev = None
            for row in samples:
                t = int(row["timestamp_unix_nano"]) / 1e9 - t0
                if row["backend"] == "backend-unhealthy":
                    if row["success"] == "true":
                        ok[int(t)] += 1
                    else:
                        bad[int(t)] += 1
                unhealthy = row["backend_phase"] == "unhealthy"
                if unhealthy and prev is not True:
                    phase_bad.append([t, None])
                if not unhealthy and prev is True and phase_bad:
                    phase_bad[-1][1] = t
                prev = unhealthy
            for start, end in phase_bad:
                axis.axvspan(start, end if end is not None else t, color=GRID, alpha=0.7, zorder=1)
            xs = list(range(int(t) + 1))
            axis.plot(xs, [ok[x] for x in xs], color=COLORS[name], linewidth=1.2, zorder=3)
            axis.plot(xs, [bad[x] for x in xs], color=CRITICAL, linewidth=2.4, zorder=4)
            failed = sum(bad.values())
            unhealthy_hits = sum(1 for r in samples if r["backend_phase"] == "unhealthy" and r["backend"] == "backend-unhealthy")
            summary.setdefault(name, {})[variant] = failed
            axis.set_title(f"{LABELS[name]} — {failed:,} failed requests; {unhealthy_hits:,} requests sent to the backend while it was unhealthy", loc="left", fontsize=10, color=INK_2)
            style(axis)
            axis.tick_params(axis="y", labelsize=8)
        axes[-1].set_xlabel("seconds since probing started — requests/s to the flapping backend (thin: succeeded, bold red: failed; shaded: backend unhealthy)")
        label = "no implementation-specific policies" if variant == "baseline" else f"policy variant: {variant}"
        heading(figure, f"Backend failover ({variant})", f"3 healthy backends plus one that flips healthy/unhealthy every 22 s — {label}", top=0.9)
        figure.tight_layout(rect=(0, 0, 1, 0.92))
        save(figure, output, "backendfailover.png" if variant == "baseline" else f"backendfailover-{variant}.png")

    if summary:
        names = ordered(summary)
        variant_names = ["baseline"] + sorted(v for v in variants if v != "baseline")
        figure, axis = plt.subplots(figsize=(8.5, 4.5))
        series = [(v, [summary[n].get(v, 0) for n in names], BLUE_RAMP[i % len(BLUE_RAMP)]) for i, v in enumerate(variant_names)]
        grouped_bars(axis, names, series)
        style(axis, ylabel="failed requests")
        heading(figure, "Backend failover: failed requests", "total non-200 responses over the run; lower is better")
        save(figure, output, "backendfailover-summary.png")


# --- scale tests (route-load / listenerset-load) --------------------------------
def load_resources(results_dir, test):
    """Returns {target: [rows]} where target is the gateway under load ('' = all)."""
    runs = defaultdict(list)
    for path in sorted(results_dir.glob(f"{test}-*-resources.csv")):
        with path.open(newline="") as source:
            for row in csv.DictReader(source):
                target = row.get("target", "") or ""
                if not target:
                    m = re.match(rf"{test}-\d{{8}}T\d{{6}}Z-\d+-(?P<gw>[a-z-]+)-resources\.csv$", path.name)
                    target = m.group("gw") if m else ""
                row["timestamp_unix_seconds"] = float(row["timestamp_unix_seconds"])
                row["value"] = float(row["value"])
                runs[target].append(row)
    return runs


def series_for(rows, gateway, plane, metric):
    points = sorted((r["timestamp_unix_seconds"], r["value"]) for r in rows if r["gateway"] == gateway and r["plane"] == plane and r["metric"] == metric)
    return points


def plot_scale(results_dir, output, test, title):
    runs = load_resources(results_dir, test)
    if not runs:
        return
    sequential = "" not in runs
    # For sequential runs each gateway's line comes from the run that targeted it.
    def own_rows(gateway):
        return runs[gateway] if sequential else runs[""]

    names = ordered(g for g in (runs if sequential else {r["gateway"] for r in runs[""]}) if g)
    panels = [
        ("control-plane", "cpu_cores", "Control plane CPU", "cores"),
        ("control-plane", "memory_bytes", "Control plane memory", "MB"),
        ("data-plane", "cpu_cores", "Data plane CPU", "cores"),
        ("data-plane", "memory_bytes", "Data plane memory", "MB"),
    ]
    figure, axes = plt.subplots(2, 2, figsize=(11, 7.5), sharex=True)
    for axis, (plane, metric, ptitle, unit) in zip(axes.flat, panels):
        for name in names:
            rows = own_rows(name)
            pl = "combined" if name == "haproxy" else plane
            if name == "haproxy" and plane == "control-plane":
                continue
            points = series_for(rows, name, pl, metric)
            if not points:
                continue
            t0 = min(r["timestamp_unix_seconds"] for r in rows)
            xs = [t - t0 for t, _ in points]
            ys = [v / 1e6 if metric == "memory_bytes" else v for _, v in points]
            axis.plot(xs, ys, color=COLORS[name], linewidth=2, marker=MARKERS[name], markersize=4, markevery=max(1, len(xs) // 10))
        axis.set_title(ptitle, loc="left", fontsize=10.5, color=INK_2)
        style(axis, ylabel=unit)
    for axis in axes[1]:
        axis.set_xlabel("seconds since the load generator started")
    mode = "each gateway measured in its own run" if sequential else "all gateways loaded at once"
    if "haproxy" in names:
        mode += "; HAProxy runs control and data plane in one pod (shown in the data-plane panels)"
    heading(figure, title, mode, top=0.84)
    legend(figure, names, where=(0.5, 0.905))
    figure.tight_layout(rect=(0, 0, 1, 0.85))
    save(figure, output, f"{test}.png")

    # network
    figure, axes = plt.subplots(1, 2, figsize=(11, 4.2), sharex=True)
    for axis, plane in zip(axes, ["control-plane", "data-plane"]):
        for name in names:
            rows = own_rows(name)
            pl = "combined" if name == "haproxy" else plane
            if name == "haproxy" and plane == "control-plane":
                continue
            points = series_for(rows, name, pl, "network_tx_bytes_per_second")
            if not points:
                continue
            t0 = min(r["timestamp_unix_seconds"] for r in rows)
            axis.plot([t - t0 for t, _ in points], [v / 1e3 for _, v in points], color=COLORS[name], linewidth=2, marker=MARKERS[name], markersize=4, markevery=max(1, len(points) // 10))
        axis.set_title(f"{plane.replace('-', ' ').capitalize()} network transmit", loc="left", fontsize=10.5, color=INK_2)
        style(axis, ylabel="KB/s", xlabel="seconds since the load generator started")
    heading(figure, f"{title}: network", f"bytes transmitted by the gateway pods; {mode}", top=0.78)
    legend(figure, names, where=(0.5, 0.88))
    figure.tight_layout(rect=(0, 0, 1, 0.8))
    save(figure, output, f"{test}-network.png")

    if not sequential:
        return

    # Bystander cost: CPU each implementation spends while another gateway's
    # routes are being generated (resources not aimed at it).
    own = {}
    other = {}
    for name in names:
        planes = ["combined"] if name == "haproxy" else ["control-plane", "data-plane"]
        def mean_cpu(rows):
            per_ts = defaultdict(float)
            for r in rows:
                if r["gateway"] == name and r["plane"] in planes and r["metric"] == "cpu_cores":
                    per_ts[r["timestamp_unix_seconds"]] += r["value"]
            return statistics.mean(per_ts.values()) if per_ts else 0.0
        own[name] = mean_cpu(runs[name])
        others = [mean_cpu(runs[t]) for t in runs if t and t != name]
        other[name] = statistics.mean(others) if others else 0.0
    figure, axis = plt.subplots(figsize=(9, 4.5))
    grouped_bars(axis, names, [("own routes (targeted)", [own[n] for n in names], BLUE_RAMP[1]), ("another gateway's routes (bystander)", [other[n] for n in names], BLUE_RAMP[0])], fmt="{:.2f}")
    style(axis, ylabel="mean CPU cores (control + data plane)")
    heading(figure, f"{title}: cost of routes aimed at other gateways", "mean CPU during its own run vs. the average over the other gateways' runs")
    save(figure, output, f"{test}-bystander.png")

    # Normalized score (report v2 formula) over the targeted runs.
    means = {}
    for name in names:
        if name == "haproxy":
            continue
        for plane in ("control-plane", "data-plane"):
            for metric in ("cpu_cores", "memory_bytes"):
                values = [v for _, v in series_for(runs[name], name, plane, metric)]
                if values:
                    means[(name, plane, metric)] = statistics.mean(values)
    scored = [n for n in names if all((n, p, m) in means for p in ("control-plane", "data-plane") for m in ("cpu_cores", "memory_bytes"))]
    if len(scored) >= 2:
        scores = {}
        for name in scored:
            parts = {"data-plane": [], "control-plane": []}
            for plane in parts:
                for metric in ("cpu_cores", "memory_bytes"):
                    best = min(means[(g, plane, metric)] for g in scored)
                    parts[plane].append(best / means[(name, plane, metric)])
            scores[name] = 0.8 * statistics.mean(parts["data-plane"]) + 0.2 * statistics.mean(parts["control-plane"])
        figure, axis = plt.subplots(figsize=(8, 4.2))
        bars(axis, scored, [scores[n] for n in scored], fmt="{:.3f}")
        axis.set_ylim(0, max(1.1, max(scores.values()) * 1.15))
        style(axis, ylabel="normalized score (1 = best in every category)")
        heading(figure, f"{title}: normalized scalability score", "80% data plane, 20% control plane; each metric relative to the best implementation (HAProxy excluded: planes not separable)")
        save(figure, output, f"{test}-normalized.png")


# --- traffic -------------------------------------------------------------------
def plot_traffic(results_dir, output):
    rows = read_rows(results_dir, "traffic", exclude=r"failures")
    if not rows:
        return
    points = defaultdict(list)
    for row in rows:
        try:
            points[(row["destination"], int(row["connections"]))].append(
                (float(row["throughput"].removesuffix("qps")), float(row["p50"].removesuffix("ms")), float(row["p99"].removesuffix("ms")))
            )
        except (KeyError, ValueError):
            continue
    names = ordered({g for g, _ in points})
    conns = sorted({c for _, c in points})

    figure, axis = plt.subplots(figsize=(9, 5))
    for name in names:
        xs = [c for c in conns if (name, c) in points]
        ys = [statistics.median(v[0] for v in points[(name, c)]) for c in xs]
        axis.plot(xs, ys, color=COLORS[name], linewidth=2, marker=MARKERS[name], markersize=6)
    axis.set_xscale("log", base=2)
    axis.set_xticks(conns)
    axis.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{int(v)}"))
    axis.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:,.0f}"))
    style(axis, ylabel="requests per second", xlabel="concurrent connections")
    heading(figure, "Traffic throughput", "fortio, uncapped QPS, 30 s per point, 100-byte payload; one gateway at a time")
    legend(figure, names)
    save(figure, output, "traffic-throughput.png")

    figure, axes = plt.subplots(1, 2, figsize=(11, 4.5), sharex=True)
    for axis, (idx, label) in zip(axes, [(1, "p50"), (2, "p99")]):
        for name in names:
            xs = [c for c in conns if (name, c) in points]
            ys = [statistics.median(v[idx] for v in points[(name, c)]) for c in xs]
            axis.plot(xs, ys, color=COLORS[name], linewidth=2, marker=MARKERS[name], markersize=6)
        axis.set_xscale("log", base=2)
        axis.set_xticks(conns)
        axis.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{int(v)}"))
        axis.set_title(f"{label} latency", loc="left", fontsize=10.5, color=INK_2)
        style(axis, ylabel="ms", xlabel="concurrent connections")
    heading(figure, "Traffic latency", "latency at the throughput above (uncapped load, so latency grows with queueing)", top=0.78)
    legend(figure, names, where=(0.5, 0.88))
    figure.tight_layout(rect=(0, 0, 1, 0.8))
    save(figure, output, "traffic-latency.png")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("results_dir", nargs="?", type=Path, default=Path("results"))
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    output = args.output_dir or args.results_dir / "graphs"
    output.mkdir(parents=True, exist_ok=True)
    for graph in output.glob("*.png"):
        graph.unlink()
    plot_attached_routes(args.results_dir, output)
    plot_attached_routes_resources(args.results_dir, output)
    plot_probe(args.results_dir, output)
    plot_routechange(args.results_dir, output)
    plot_backendfailover(args.results_dir, output)
    plot_scale(args.results_dir, output, "route-load", "Route scale")
    plot_scale(args.results_dir, output, "listenerset-load", "ListenerSet scale")
    plot_traffic(args.results_dir, output)
    print(f"generated {len(list(output.glob('*.png')))} graph(s) in {output}")


if __name__ == "__main__":
    main()
