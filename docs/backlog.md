# Backlog

What is not built yet, and what it is waiting on. An item leaves this file when
it is done, not when it is started.

## Public access, with `cloudflared`

**Nothing is reachable from the internet yet.** The mesh path works end to end;
the public one is built up to the last hop and stops there.

`gw-public` already exists and already has an `HTTPRoute` listener on
`*.apps.homelab.grncunha.com`. It is a `ClusterIP`, so nothing outside the
cluster can dial it, and nothing does. What is missing is the thing that dials
it from inside.

### What it needs

| Piece | Detail |
| --- | --- |
| Tunnel | Created in Cloudflare Zero Trust. It is shown once, so it goes straight into `gitops/secrets/` as a `SopsSecret` |
| `cloudflared` | A `Deployment`, two replicas, in `gitops/system/base/` |
| Routing | A ConfigMap, so the routing table is in git rather than the Cloudflare dashboard |
| DNS | A `cloudflare-proxied: "true"` annotation on `gw-public`, plus `target: <tunnel-id>.cfargotunnel.com`. external-dns writes the rest |

One catch-all ingress rule is enough:
`*.apps.homelab.grncunha.com` to `http://gw-public.gateway-system.svc:80`, with
the `Host` header preserved. Adding a public app then never touches this config
again -- it is one more `HTTPRoute`, exactly like a mesh one.

### Why it is shaped this way

The tunnel opens itself, outbound. Nothing new listens on the host, the firewall
does not change, and the server keeps accepting `22`, `80` and `443` and nothing
else. That is the whole reason for choosing a tunnel over a port forward.

A tunnel CNAME only resolves when proxied, which is the one place in this repo
where an orange cloud is correct. Everything else made by hand must stay DNS
only; see [Names](./architecture/names.md).

`gw-public` needs no certificate. Cloudflare terminates TLS at the edge and the
tunnel carries its own, so the last hop is inside the cluster.
[Getting traffic into the cluster](./concepts/ingress.md) has the reasoning.

### Done when

An app on `*.apps.homelab.grncunha.com` answers over HTTPS from a device that is
**not** on the mesh, `cloudflared` logs four registered connections, and an
`nmap` of the server from outside still shows only `22`, `80` and `443`.

## Persistent storage

Nothing has any. A pod asking for a volume stays `Pending`, and that is expected
rather than broken. ArgoCD and cert-manager do not need it; most real
applications do, so this is what blocks the cluster being useful for anything
that keeps state.

No decision made yet on what provides it.
