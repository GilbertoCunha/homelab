# Homelab

Welcome to my homelab!

In this repo, I configure a dedicated server I have running:

- **OS**: debian 13
- **Mesh Network**: Headscale
- **Virtualization**: Proxmox
- **Public Access**: Cloudflare tunnels
- **Container Orchestration**: Kubernetes

To get it running, read the [Operator Manual](./docs/manual/index.md).
When something breaks, read [Applying step by step](./docs/troubleshooting/step-by-step.md).
For the commands you reach for most, see the [Cheatsheet](./docs/cheatsheet.md).

## Architecture

One Hetzner dedicated server. Headscale and Proxmox both run on the host itself,
not inside a VM.

The server is the only machine reachable from the internet. It accepts SSH, HTTP
and HTTPS, and nothing else. Caddy terminates TLS and forwards to Headscale,
which runs on loopback.

Proxmox guests have no public address. They sit on a private bridge and reach the
internet through NAT. To reach a guest, you join the mesh: the guest runs a
Tailscale client that registers with Headscale, and your laptop talks to it over
that. The server does the same.

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

your laptop ──▶ mesh ──▶ proxmox UI :8006, and guests directly
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
| `10.244.0.0/16` | Kubernetes pods | reserved |
| `10.96.0.0/12` | Kubernetes services | reserved |
| `172.17.0.0/16` | Docker's default bridge | avoid |

Two notes on the choices:

- Tailscale normally uses the whole `100.64.0.0/10` range. A `/16` is narrower
  and still holds 65,000 nodes. Headscale cannot change this range once nodes
  have registered, so it is worth getting right the first time.
- `10.96.0.0/12` reaches all the way to `10.111.255.255`. Guest bridges sit at
  `10.10.x` to stay well clear of it.

Guests get static addresses. Nothing on the server hands out DHCP leases.
