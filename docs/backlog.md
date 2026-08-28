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
