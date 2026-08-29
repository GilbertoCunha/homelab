# Backlog

What is not built yet, and what it is waiting on. An item leaves this file when
it is done, not when it is started.

## Reloading pods on config changes

Nothing restarts a pod when its ConfigMap or Secret changes. `cloudflared`
reads its config only at startup, so a routing change applies cleanly and is
then ignored until something else restarts it. The same is true of its
credentials.

Reloader is the likely answer: one controller, an annotation per workload.

VictoriaMetrics is the exception, and shows the other way out: it watches its own
config file, so its scrape jobs reload without anything restarting it.

## Replicated storage

There is storage, but it is node-local: a volume is a directory on whichever
worker its pod landed on, and the pod cannot leave that worker. See
[The cluster's storage](./concepts/storage.md).

Longhorn is the likely answer. The `iscsi-tools` Talos extension it needs is
already in the image, precisely so adding it later does not cost a rolling
upgrade of every node.

Worth doing once something holds data that is not cheap to lose. Metrics and
logs are not that.

## Waypoints, and strict mTLS

Istio runs in ambient mode, which means ztunnel and L4 only: identity and
encryption between pods, and nothing that understands HTTP. See
[Istio in ambient mode](./concepts/istio.md).

Two things are deliberately not done yet:

- **A waypoint**, which is what adds L7 — per-path policy, retries, request
  telemetry. It is one `Gateway` with `gatewayClassName: istio-waypoint`, added
  per namespace, and worth doing the first time a workload actually needs one
  rather than in advance.
- **`PeerAuthentication` with `mode: STRICT`**, which refuses plaintext
  entirely. Permissive is what lets a namespace be enrolled without every
  unenrolled caller breaking at the same moment. Worth doing once everything
  that talks to an enrolled namespace is itself enrolled.

## Backups

Defining a strategy for anything that might need backups, including potentially
the cluster itself.

For peace of mind to allow recovery in the case of a disaster.

Velero is a potential option to look at.

