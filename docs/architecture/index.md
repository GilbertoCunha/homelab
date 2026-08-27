# Architecture

How the pieces fit together, and why the shape is what it is. This is the
"what is the system" document; for how to run it, see the
[Operator Manual](../manual/index.md).

- [Names](./names.md): what every name is, and the pattern new ones follow
- [Networks and addresses](./networks.md): every range and address in use.
  Check it before allocating either

One Hetzner dedicated server. Headscale and Proxmox both run on the host itself,
not inside a VM.

The server is the only machine reachable from the internet. It accepts SSH, HTTP
and HTTPS, and nothing else. Caddy terminates TLS and forwards to Headscale,
which runs on loopback.

Proxmox guests have no public address. They sit on a private bridge and reach the
internet through NAT. To reach a guest, you join the mesh: the server advertises
the guest subnet into it and forwards the traffic, so a guest needs no mesh
client of its own.

The guests are a six-node Kubernetes cluster running Talos Linux, built by
OpenTofu.

The Proxmox interface is served by Caddy at `proxmox.homelab.grncunha.com`, with
a real certificate, but only to mesh devices. The name answers differently
depending on who asks: Headscale gives mesh devices the server's mesh address,
while everyone else gets the public one, which is what lets the certificate
renew. Caddy answers `403` to anything that is not a mesh address.

```
internet ──▶ 22, 80, 443 ──▶ homelab.grncunha.com
                              ├── caddy ──▶ headscale (loopback)
                              ├── tailscale client ──▶ mesh
                              └── proxmox ──▶ vmbr1 ──▶ guests (NAT, no public IP)
                                                        ├── cp-1..3      ──▶ etcd, kube-apiserver
                                                        └── worker-1..3  ──▶ workloads

internet ──▶ cloudflare edge ──▶ tunnel ──▶ cloudflared (in cluster)
                                             └──▶ gw-public ──▶ <app>.grncunha.com

your laptop ──▶ mesh ──▶ proxmox UI :8006
                     └──▶ 10.10.10.0/24, routed by the server
                           ├──▶ guests
                           ├──▶ .200  gw-internal-prod ──▶ prod apps
                           └──▶ .201  gw-internal-dev  ──▶ dev apps
```

Both halves run. The public one carries no certificate of its own: Cloudflare
terminates TLS at the edge and the tunnel carries its own inside. See
[Opening the tunnel](../manual/provisioning/5-open-the-tunnel.md).

## Where the boundaries are

Three tools own three layers, and the boundary between each pair is an API
rather than a shared file:

| Tool | Owns | Hands over at |
| --- | --- | --- |
| Ansible | The server itself | The Proxmox API |
| OpenTofu | The guests, and the cluster that runs on them | The Kubernetes API |
| ArgoCD | Everything inside the cluster | — |

Nothing reaches across a boundary. That is why adding a workload is a commit
rather than a run of anything, and why rebuilding the cluster does not touch the
server. [GitOps with ArgoCD](../concepts/gitops.md) covers the last of the
three.
