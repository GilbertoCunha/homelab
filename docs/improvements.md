# Improvements

Things that work but are not right yet. Everything here is running; the
[backlog](./backlog.md) is for what is not built at all.

## cloudflared does not meet the restricted PodSecurity profile

`kubectl` warns on every apply: no `runAsNonRoot`, `allowPrivilegeEscalation`,
`capabilities.drop` or `seccompProfile`. Warn-only, so nothing is blocked, but
it is the one workload reachable from the internet.

## Routes disagree on `sectionName`

[Exposing a service](./manual/maintenance/exposing-a-service.md) says to set it.
`gitops/system/base/cilium/route.yaml` and ArgoCD's own route do not. Either
the document or the manifests should change.

## Persistent storage

`victoria-metrics`, `victoria-logs` and `grafana` all keep a volume now.
`gitops/system/base/victoria-traces/` and `gitops/system/base/otel/` are empty
directories: nothing is deployed, so there is nothing to give a volume to yet.

## The uptime check's resource requests are guesses

The blackbox exporter, `probe-targets` and ntfy were given requests before any
of them had run. Every other system component is sized from `kubectl top`.
Measure them after a day and replace the figures; each manifest says so.

## etcd and kubelet logs are not collected

The log collector reads pod logs on every node. etcd and the kubelet are Talos
services, not pods, so none of their output reaches VictoriaLogs.
`talosctl logs` is the only way to read them, which means the one place a
cluster-wide failure shows up first is the one place there is no search.
Talos can send its service logs to a remote endpoint (`machine.logging`), which
is the likely way in.

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

