# Networks and addresses

**Check the tables here before allocating a range or an address, and add what
you allocate to them.** Overlapping ranges are painful to debug once traffic is
flowing, and a duplicate address fails in ways that look like something else.

## Ranges

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

## Guest addresses

Everything on `vmbr1`. Guests get static addresses; nothing on the server hands
out DHCP leases, which is why a Talos guest is given its first address by a
cloud-init drive rather than finding one itself.

| Address | Guest | Notes |
| --- | --- | --- |
| `10.10.10.1` | The server | The bridge, and the gateway every guest uses. Port `9100` answers guests with the server's own metrics |
| `10.10.10.10` | Kubernetes API | Virtual, held by the control plane |
| `10.10.10.11` | `cp-1` | Control plane. `.12`-`.19` are kept for more |
| `10.10.10.21` | `worker-1` | Worker. `.22`-`.29` are kept for more |
| `10.10.10.31` | `system-1` | System node. `.32`-`.39` are kept for more |
| `10.10.10.100`-`.199` | Free | For anything that is not a cluster node |
| `10.10.10.200`-`.209` | The Gateways | Fixed, one each, and what DNS points at. `.200` prod, `.201` dev. See [Getting traffic into the cluster](../concepts/ingress.md) |
| `10.10.10.210`-`.250` | Other Kubernetes LoadBalancers | Assigned by Cilium in the order they are asked for, so not stable across a rebuild. Reach them by name |
| `10.10.10.251`-`.254` | Free | |

What each node is for, and how big it is, is in
[Node pools](../concepts/node-pools.md).
