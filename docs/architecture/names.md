# Names

Everything derives from the apex domain, `grncunha.com`, and nests under the
server name. Where a name sits says what serves it and how it is added.

| Name | What it is | Reachable from |
| --- | --- | --- |
| [`proxmox.homelab.grncunha.com`](https://proxmox.homelab.grncunha.com) | Proxmox web interface | the mesh only |
| [`vpn.homelab.grncunha.com`](https://vpn.homelab.grncunha.com) | Headscale, where devices join the mesh | anywhere, by design |
| `homelab.grncunha.com` | The server itself, over SSH | anywhere |
| `<node>.mesh.homelab.grncunha.com` | Any mesh node, by name | the mesh only |
| `<app>.k8s.homelab.grncunha.com` | Any cluster workload, prod | the mesh only |
| `<app>.dev.k8s.homelab.grncunha.com` | Any cluster workload, dev | the mesh only |
| `<app>.apps.homelab.grncunha.com` | Any cluster workload published to the internet | anywhere |
| `grncunha.com` | Apex domain | — |

The server's public IP is not recorded anywhere in this repo. It lives in the
Cloudflare DNS records, and everything else resolves it from there.

## The pattern

Services nest under the thing that serves them, so where a name sits says what
runs it:

| Pattern | Served by | Certificate from |
| --- | --- | --- |
| `<service>.homelab.grncunha.com` | Caddy, on the host | Caddy, HTTP-01 |
| `<app>.k8s.homelab.grncunha.com` | The cluster, prod | cert-manager, DNS-01 wildcard |
| `<app>.dev.k8s.homelab.grncunha.com` | The cluster, dev | cert-manager, DNS-01 wildcard |
| `<app>.apps.homelab.grncunha.com` | The cluster, published | Cloudflare, at the edge |

A name under `homelab` is added by hand: a Cloudflare record, and a Caddy site.
A name under `k8s` or `apps` is not added at all -- external-dns writes the
record from the `HTTPRoute`, and the Gateway already holds the certificate. See
[Exposing a service](../manual/maintenance/exposing-a-service.md).

Records made by hand must be **DNS only**, the grey cloud. Cloudflare's proxy
breaks certificate issuance for Caddy and drops the UDP the mesh needs. The
exception is the public cluster path, which only works proxied because a tunnel
CNAME requires it -- and that record is not made by hand either. external-dns
writes it, proxied, decided by the Gateway the route attaches to. See
[Getting traffic into the cluster](../concepts/ingress.md).
