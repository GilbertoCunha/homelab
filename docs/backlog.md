# Backlog

What is not built yet, and what it is waiting on. An item leaves this file when
it is done, not when it is started.

## Persistent storage

Nothing has any. A pod asking for a volume stays `Pending`, and that is expected
rather than broken. ArgoCD and cert-manager do not need it; most real
applications do, so this is what blocks the cluster being useful for anything
that keeps state.

No decision made yet on what provides it.
