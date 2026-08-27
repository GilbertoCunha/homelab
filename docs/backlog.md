# Backlog

What is not built yet, and what it is waiting on. An item leaves this file when
it is done, not when it is started.

## Reloading pods on config changes

Nothing restarts a pod when its ConfigMap or Secret changes. `cloudflared`
reads its config only at startup, so a routing change applies cleanly and is
then ignored until something else restarts it. The same is true of its
credentials.

Reloader is the likely answer: one controller, an annotation per workload.

## Persistent storage

Nothing has any. A pod asking for a volume stays `Pending`, and that is expected
rather than broken. ArgoCD and cert-manager do not need it; most real
applications do, so this is what blocks the cluster being useful for anything
that keeps state.

No decision made yet on what provides it.
