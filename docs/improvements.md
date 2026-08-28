# Improvements

Things that work but are not right yet. Everything here is running; the
[backlog](./backlog.md) is for what is not built at all.

## cloudflared has no resource requests

Both pods are `BestEffort`, so they are among the first evicted under memory
pressure, and they are the whole public path. Nothing in `gitops/` sets
`resources` on anything.

## cloudflared does not meet the restricted PodSecurity profile

`kubectl` warns on every apply: no `runAsNonRoot`, `allowPrivilegeEscalation`,
`capabilities.drop` or `seccompProfile`. Warn-only, so nothing is blocked, but
it is the one workload reachable from the internet.

## Nothing has a PodDisruptionBudget

`cloudflared` and each Envoy run two replicas, spread across nodes. A drain can
still take both at once.

## Routes disagree on `sectionName`

[Exposing a service](./manual/maintenance/exposing-a-service.md) says to set it.
`gitops/system/base/cilium/route.yaml` and ArgoCD's own route do not. Either
the document or the manifests should change.

## Persistent storage

`victoria-metrics`, `victoria-logs` and `grafana` all keep a volume now.
`gitops/system/base/victoria-traces/` and `gitops/system/base/otel/` are empty
directories: nothing is deployed, so there is nothing to give a volume to yet.

## Control-plane logs are not collected

The log collector is a DaemonSet, and the control planes are tainted, so it runs
on the three workers only. etcd, the API server, the scheduler and the
controller manager are static pods on `cp-1` to `cp-3`, and none of their output
reaches VictoriaLogs. `talosctl logs` is the only way to read them, which means
the one place a cluster-wide failure shows up first is the one place there is no
search.

## Metric retention is written down nowhere

Logs are kept 7 days, set explicitly. Metrics are kept one month, which is the
chart's default and appears in no file in this repo. Whichever figure is right,
both should be a decision rather than one decision and one accident.

## No node-level metrics

There is no node-exporter, so nothing named `node_*` exists. Host disk usage and
filesystem pressure are invisible, and there is no history for either. That
matters more here than it would elsewhere: every volume is node-local, and
nothing would warn before a worker's disk filled.

metrics-server does not close this. It answers what a node is using *now*, which
is what `kubectl top` and the front page read; it stores nothing and knows
nothing about disks.

## Grafana integration

- `victoria-traces`, once it exists at all
- There is no published log-browsing dashboard that uses the current
  `victoriametrics-logs-datasource` id. The one that exists, 21550, still asks
  for `victorialogs-datasource`, which grafana.com no longer serves. Log panels
  have to be built by hand

