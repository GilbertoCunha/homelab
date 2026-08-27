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
| `10.10.10.1` | The server | The bridge, and the gateway every guest uses |
| `10.10.10.10` | Kubernetes API | Virtual, shared by the control planes |
| `10.10.10.11`-`.13` | `cp-1` to `cp-3` | Control planes: 2 vCPU, 4 GB, 40 GB |
| `10.10.10.21`-`.23` | `worker-1` to `worker-3` | Workers: 4 vCPU, 20 GB, 100 GB |
| `10.10.10.100`-`.199` | Free | For anything that is not a cluster node |
| `10.10.10.200`-`.250` | Kubernetes LoadBalancers | Assigned by Cilium, not by a machine. See [Getting traffic into the cluster](../concepts/ingress.md) |
| `10.10.10.251`-`.254` | Free | |

The cluster uses 18 vCPU against the host's 12 threads and 72 GB of its 125 GB.
That leaves roughly 53 GB for the server itself.
