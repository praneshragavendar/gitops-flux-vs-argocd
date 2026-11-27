#!/usr/bin/env python3
"""Query Prometheus and print a Markdown table of Flux vs Argo CD metrics.

Usage: python3 ci/prom_query.py http://localhost:9090
Every query is optional: if a metric is missing (e.g. renamed in a newer release),
the cell shows "n/a" instead of failing the CI job.
"""

import json
import sys
import urllib.parse
import urllib.request

PROM = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:9090"


def query(promql):
    """Run an instant query and return a list of (labels, value) pairs."""
    url = f"{PROM}/api/v1/query?" + urllib.parse.urlencode({"query": promql})
    try:
        with urllib.request.urlopen(url, timeout=20) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:  # network error, bad query, Prometheus not ready
        print(f"<!-- query failed: {promql}: {exc} -->")
        return []
    return [(r["metric"], float(r["value"][1])) for r in data.get("data", {}).get("result", [])]


def first_value(promql):
    rows = query(promql)
    return rows[0][1] if rows else None


def by_label(promql, label):
    return {labels.get(label, "?"): value for labels, value in query(promql)}


def fmt(value, unit="", digits=2):
    return "n/a" if value is None else f"{value:.{digits}f}{unit}"


ns = 'namespace=~"flux-system|argocd"'
cpu = by_label(f'sum by (namespace) (rate(container_cpu_usage_seconds_total{{{ns},container!=""}}[5m]))', "namespace")
mem = by_label(f'sum by (namespace) (container_memory_working_set_bytes{{{ns},container!=""}}) / 1024 / 1024', "namespace")
targets = by_label(f'count by (namespace) (up{{{ns}}} == 1)', "namespace")

# Average reconcile time since the controllers started (same metric as the Grafana dashboard).
flux_reconcile = first_value(
    'sum(controller_runtime_reconcile_time_seconds_sum{namespace="flux-system",controller=~"kustomization.*"}) / '
    'sum(controller_runtime_reconcile_time_seconds_count{namespace="flux-system",controller=~"kustomization.*"})'
)
if flux_reconcile is None:
    # Fallback: Flux's own reconcile histogram
    flux_reconcile = first_value(
        'sum(gotk_reconcile_duration_seconds_sum{kind="Kustomization"}) / sum(gotk_reconcile_duration_seconds_count{kind="Kustomization"})'
    )
argo_reconcile = first_value("sum(argocd_app_reconcile_sum) / sum(argocd_app_reconcile_count)")

print("### Metrics collected by Prometheus (kind cluster on a GitHub Actions runner)")
print()
print("| Metric | Flux CD | Argo CD |")
print("| --- | --- | --- |")
print(f"| Prometheus scrape targets up | {fmt(targets.get('flux-system'), digits=0)} | {fmt(targets.get('argocd'), digits=0)} |")
print(f"| Avg reconcile / app refresh time | {fmt(flux_reconcile, ' s', 3)} | {fmt(argo_reconcile, ' s', 3)} |")
print(f"| CPU used by the tool (cores, 5m rate) | {fmt(cpu.get('flux-system'), digits=3)} | {fmt(cpu.get('argocd'), digits=3)} |")
print(f"| Memory used by the tool (MiB) | {fmt(mem.get('flux-system'), digits=0)} | {fmt(mem.get('argocd'), digits=0)} |")
