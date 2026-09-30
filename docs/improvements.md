# Improvements

Things that work but are not right yet. Everything here is running; the
[backlog](./backlog.md) is for what is not built at all.

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

## etcd and kubelet logs are not collected

The log collector reads pod logs on every node. etcd and the kubelet are Talos
services, not pods, so none of their output reaches VictoriaLogs.
`talosctl logs` is the only way to read them, which means the one place a
cluster-wide failure shows up first is the one place there is no search.
Talos can send its service logs to a remote endpoint (`machine.logging`), which
is the likely way in.

## Node sizes and CPU weights are a first guess

The sizes and CPU weights in [Node pools](./concepts/node-pools.md) were set on
2026-09-30 from one afternoon of `kubectl top`, before node-exporter existed.
None of them has been checked against a busy host.

Check the Node pools dashboard in Grafana after a few weeks of real use:

| Signal | Means |
| --- | --- |
| Sustained CPU steal above 5% on a worker | The weights or the total vCPUs need another look |
| A pool's CPU or memory requested above 80% | The pool is close to refusing new pods |
| System nodes mostly idle | They could shrink, and give the host back memory |

[Resizing a node](./manual/maintenance/resizing-a-node.md) is the procedure.
This item leaves once the numbers have been checked.

## Metric retention is written down nowhere

Logs are kept 7 days, set explicitly. Metrics are kept one month, which is the
chart's default and appears in no file in this repo. Whichever figure is right,
both should be a decision rather than one decision and one accident.

## Grafana integration

- `victoria-traces`, once it exists at all
- There is no published log-browsing dashboard that uses the current
  `victoriametrics-logs-datasource` id. The one that exists, 21550, still asks
  for `victorialogs-datasource`, which grafana.com no longer serves. Log panels
  have to be built by hand

