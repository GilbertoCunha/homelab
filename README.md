# Homelab

Welcome to my homelab!

In this repo, I configure a dedicated server I have running:

- **OS**: debian 13
- **Mesh Network**: Headscale
- **Virtualization**: Proxmox
- **Public Access**: Cloudflare tunnels
- **Container Orchestration**: Kubernetes, on Talos Linux
- **Provisioning**: OpenTofu

## References

- To get it running, read the [Operator Manual](./docs/manual/index.md).
- When something breaks, read [Applying step by step](./docs/troubleshooting/step-by-step.md).
- For the commands you reach for most, see the [Cheatsheet](./docs/cheatsheet.md).
- For how a piece of this works rather than how to run it, see [Concepts](./docs/concepts/), starting with [The mesh network](./docs/concepts/mesh.md), [The cluster's networking](./docs/concepts/cilium.md) and [Secrets with SOPS](./docs/concepts/sops.md).

## Architecture

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
OpenTofu. Ansible owns the server itself; OpenTofu owns everything inside it,
and the Proxmox API is the line between them.

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

your laptop ──▶ mesh ──▶ proxmox UI :8006
                     └──▶ 10.10.10.0/24, routed by the server ──▶ guests
```

### Names and links

Everything derives from the apex domain. Services sit under the server name, so
adding one means adding `<service>.homelab.grncunha.com` and a matching DNS
record.

| Name | What it is | Reachable from |
| --- | --- | --- |
| [`proxmox.homelab.grncunha.com`](https://proxmox.homelab.grncunha.com) | Proxmox web interface | the mesh only |
| [`vpn.homelab.grncunha.com`](https://vpn.homelab.grncunha.com) | Headscale, where devices join the mesh | anywhere, by design |
| `homelab.grncunha.com` | The server itself, over SSH | anywhere |
| `<node>.mesh.homelab.grncunha.com` | Any mesh node, by name | the mesh only |
| `grncunha.com` | Apex domain | — |

The server's public IP is not recorded anywhere in this repo. It lives in the
Cloudflare DNS records, and everything else resolves it from there.

### Networks

Check this table before allocating a new network, and add the new one to it.
Overlapping ranges are hard to debug once traffic is flowing.

| Range | Used by | Status |
| --- | --- | --- |
| `100.64.0.0/16` | Mesh addresses, handed out by Headscale | in use |
| `10.10.10.0/24` | Proxmox guests on `vmbr1`; the server is `.1` | in use |
| `10.10.20.0/24` | A second guest bridge, if one is ever needed | reserved |
| `10.244.0.0/16` | Kubernetes pods | in use |
| `10.96.0.0/12` | Kubernetes services | in use |
| `172.17.0.0/16` | Docker's default bridge | avoid |

Two notes on the choices:

- Tailscale normally uses the whole `100.64.0.0/10` range. A `/16` is narrower
  and still holds 65,000 nodes. Headscale cannot change this range once nodes
  have registered, so it is worth getting right the first time.
- `10.96.0.0/12` reaches all the way to `10.111.255.255`. Guest bridges sit at
  `10.10.x` to stay well clear of it.

Guests get static addresses. Nothing on the server hands out DHCP leases, which
is why a Talos guest is given its first address by a cloud-init drive rather than
finding one itself.

### Guest addresses

Check this table before giving a new guest an address.

| Address | Guest | Notes |
| --- | --- | --- |
| `10.10.10.1` | The server | The bridge, and the gateway every guest uses |
| `10.10.10.10` | Kubernetes API | Virtual, shared by the control planes |
| `10.10.10.11`-`.13` | `cp-1` to `cp-3` | Control planes: 2 vCPU, 4 GB, 40 GB |
| `10.10.10.21`-`.23` | `worker-1` to `worker-3` | Workers: 4 vCPU, 20 GB, 100 GB |
| `10.10.10.100`-`.254` | Free | For anything that is not a cluster node |

The cluster uses 18 vCPU against the host's 12 threads and 72 GB of its 125 GB.
That leaves roughly 53 GB for the server itself.
