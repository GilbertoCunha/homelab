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
`gitops/network/base/hubble-route.yaml` and ArgoCD's own route do not. Either
the document or the manifests should change.

## Persistent storage

There is no persistent storage configuration for either:

- `victoria-metrics`
- `victoria-logs`
- `victoria-traces`
- `otel`
- `grafana`

## Grafana integration

Integrate into Grafana:

- `victoria-logs`
- `victoria-traces`
- More dashboards to monitor important services
- Check if all metrics and logs and traces are being properly collected

