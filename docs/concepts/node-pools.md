# Node pools

The cluster's nodes are split into three pools, so that the components running
the cluster and the applications running on it do not compete for the same
nodes.

| Pool | Nodes | Runs | Label | Keeps others off with |
| --- | --- | --- | --- | --- |
| Control plane | `cp-1` | etcd, the API server, the scheduler, the controller manager | `node-role.kubernetes.io/control-plane`, set by Talos | The taint of the same name, `NoSchedule` |
| System | `system-1` | The cluster's own components | `homelab.grncunha.com/pool=system` | `homelab.grncunha.com/pool=system:NoSchedule` |
| Worker | `worker-1` | Applications, and the Gateways in front of them | `homelab.grncunha.com/pool=worker` | Nothing |

## Sizes

This is the one place in the docs that says how many nodes there are and how
big they are. Everywhere else links here.

| Pool | Nodes | vCPU each | Memory each | Disks each | CPU weight |
| --- | --- | --- | --- | --- | --- |
| Control plane | 1 | 2 | 8 GiB | 40 GB | 150 |
| System | 1 | 2 | 16 GiB | 40 GB + 100 GB data | 100 |
| Worker | 1 | 10 | 64 GiB | 100 GB + 100 GB data | 200 |
| **Total** | **3** | **14** | **88 GiB** | | |

The host has 6 cores, 12 threads and 125 GiB of usable memory. The guests share
10 of those threads; see [Host threads](#host-threads). That makes 1.4:1 CPU
overcommit, and leaves about 37 GiB for the host itself.

The worker has a vCPU for every thread the guests share. The control plane and
the system node idle at about 0.3 vCPUs each, so the worker can use nearly all
10. When all three are busy at once, the [CPU weights](#cpu-weights) decide who
waits.

`opentofu/project/locals.tf` is what actually sets these. Change a size there
and update this table in the same commit. Addresses are in
[Networks and addresses](../architecture/networks.md). The data disk holds
persistent volumes; see [The cluster's storage](./storage.md).

## Why one node per pool

Every node is a guest on the same server. More nodes in a pool therefore buy no
redundancy: when the server stops, they all stop. What they do cost is CPU.

A packet going from one guest to another is handled three times: by the sending
guest's kernel, by the server, and by the receiving guest's kernel. Until
2026-10-01 the cluster had 3 control planes, 2 system nodes and 3 workers, and
one request crossed between guests at every step: into the node holding the
Gateway's address, on to a system node for Envoy, on to a worker for the
application, and again for its database and cache.

Now the Gateways' Envoys, the applications and their databases share one
worker, and a request crosses between guests only on its way in and out.

The same load test, `peak.js` from the `system-design` repo, was run from a
laptop on the mesh against both layouts on 2026-10-01. It holds 10,000 requests
a second for a minute. The worker had 8 vCPUs at the time:

| During the hold | 8 nodes, 28 vCPUs | 3 nodes, 12 vCPUs |
| --- | --- | --- |
| Requests served per second | 9,986 | 9,978 |
| Response time, 95th percentile | 397 ms | 81 ms |
| Response time, 99th percentile | 493 ms | 96 ms |
| Iterations k6 could not start on time | 8,425 | 47 |
| vCPUs busy, all guests | 8.3 | 5.8 |
| of which handling packets in the kernel (`softirq`, `irq`) | 2.1 | 0.9 |
| CPU steal, all guests | 3.8 | 0.3 |
| Host threads busy, of 12 | 10.1 | 7.4 |
| Host threads idle | 1.5 | 4.0 |
| vCPUs busy with no load at all | 1.5 | 0.7 |

About 50 ms of every response time is the laptop's path to the server, which
neither layout changes.

What this gives up:

| Lost | Why it is acceptable here |
| --- | --- |
| A rolling restart of a pool | Restarting a node stops what it runs. [Resizing a node](../manual/maintenance/resizing-a-node.md) says what stops for each |
| etcd with three members | One server was never going to survive its own failure. The cluster is rebuilt from git; see [Bootstrap GitOps](../manual/provisioning/4-bootstrap-gitops.md) |
| Spreading replicas across nodes | Each component runs one replica. A second on the same node survives nothing the first does not |

Adding a node back to a pool is one number in `locals.tf`. It is worth doing
again once there is a second server for it to run on.

## Host threads

The server has work of its own: the mesh client decrypts every packet from a
mesh device, the guest bridge passes every packet between guests, and Proxmox
runs. With guests free to use all 12 threads, that work waits behind them.

So guests are confined to 10 threads, and the server keeps one core:

| Threads | Used by |
| --- | --- |
| 0 and 6, the two threads of core 0 | The server itself |
| 1 to 5 and 7 to 11 | Every guest |

The `proxmox` Ansible role sets this once for all guests, as `AllowedCPUs` on
`qemu.slice`, from `proxmox_guest_cpus`. Proxmox has a per-guest `affinity`
option that would put it beside the sizes in `locals.tf`, but only `root` may
set it, and OpenTofu is not `root`.

Check it on the server:

```bash
cat /sys/fs/cgroup/qemu.slice/cpuset.cpus
```

```
1-5,7-11
```

The Node pools dashboard in Grafana shows both sides, under **Host threads in
use**: what the guests use, and what the server itself uses. The mesh client
alone took a full thread at 10,000 requests a second from a laptop.

## Why workers carry no taint

A **taint** is a mark on a node that repels every pod that does not
**tolerate** it. Only the system node and the control plane carry one, so:

- An application needs no scheduling settings at all. It cannot land on the
  control plane or the system node, so it lands on a worker.
- A system component needs two settings, and both are its own business: a
  toleration, so it may land on a system node, and a `nodeSelector`, so it must.

A toleration alone is not enough. It allows a system node without requiring
one, and the pod would still land on a worker half the time.

Workers do carry a label, `homelab.grncunha.com/pool=worker`. Nothing needs it
to stay off the other pools. It is there for what has to name the workers
outright:

| Selects the worker label | Why |
| --- | --- |
| Each Gateway's Envoy, in `gitops/system/base/kgateway/gateway-parameters.yaml` | It lives under `gitops/system/`, where everything else selects the system pool. The selector says this one is deliberate |
| The load balancer announcements, in `gitops/system/base/cilium/l2-announcement.yaml` | An address must be held by the node its packets are for; see [Getting traffic into the cluster](./ingress.md#why-externaltrafficpolicy-local) |

## What runs where

| Where | What |
| --- | --- |
| System node only | ArgoCD, the blackbox exporter and its target list, cert-manager, cloudflared, the CloudNativePG operator, both external-dns instances, Grafana, kgateway's controller, kube-state-metrics, local-path-provisioner, metrics-server, ntfy, Pyroscope and its Alloy, sops-secrets-operator, VictoriaLogs, VictoriaMetrics, Hubble relay and UI |
| Every node | Cilium's agent and its Envoy, node-exporter, the log collector |
| Worker | Every Gateway's Envoy, every application, and every database CloudNativePG creates for one |
| Control plane or worker | Cilium's operator and CoreDNS. Their installers let them onto the control plane, not the system node, and they are left as installed |

The Gateways' Envoys are the way into the cluster, and they used to run on the
system nodes so an application's load could not starve them. That put a hop
between guests into every request. On the worker, two settings do the same job:

| Setting | What it does |
| --- | --- |
| A CPU request | Envoy's share of the worker when the applications want the same CPUs |
| `--concurrency` | Envoy's number of worker threads, so it cannot take the whole worker either |

Both are in `gateway-parameters.yaml`, per Gateway.

A new system component needs both settings below. Without them it lands on a
worker, and nothing warns you.

## The label and the taint

Both use the same key and value:

```yaml
tolerations:
  - key: homelab.grncunha.com/pool
    operator: Equal
    value: system
    effect: NoSchedule
nodeSelector:
  homelab.grncunha.com/pool: system
```

`opentofu/project/locals.tf` defines them for the nodes: `system_pool` for the
system node, and `worker_pool` for the worker's label. Each system component
repeats them under `gitops/system/`, because a manifest ArgoCD applies cannot
read an OpenTofu value.

The key is not `node-role.kubernetes.io/system`. Kubernetes forbids a worker
from setting labels under `kubernetes.io`, and a system node is a worker as far
as Talos is concerned.

To check every node's pool:

```bash
kubectl get nodes -L homelab.grncunha.com/pool
```

```
NAME       STATUS   ROLES           AGE   VERSION   POOL
cp-1       Ready    control-plane   10m   v1.36.2
system-1   Ready    <none>          10m   v1.36.2   system
worker-1   Ready    <none>          10m   v1.36.2   worker
```

## A taint is set once

Talos sets the label through `machine.nodeLabels`, and keeps it in step with
the configuration.

The taint works differently. Kubernetes lets a worker set taints on itself only
when it first registers, never afterwards. So the taint is given to the kubelet
as `registerWithTaints`, and it reaches a node only when that node first joins.
Changing it in `cluster.tf` changes nothing on a running node. To change a
running node, do it by hand, and change `cluster.tf` too so a rebuilt node
matches:

```bash
kubectl taint nodes system-1 homelab.grncunha.com/pool=system:NoSchedule
```

```
node/system-1 tainted
```

To check every node's taints:

```bash
kubectl get nodes -o 'custom-columns=NAME:.metadata.name,TAINTS:.spec.taints[*].key'
```

```
NAME       TAINTS
cp-1       node-role.kubernetes.io/control-plane
system-1   homelab.grncunha.com/pool
worker-1   <none>
```

## CPU weights

Every node is a guest on one host, and together they have more vCPUs than the
10 threads they share. When those threads are busy, Proxmox shares them by each
guest's **CPU weight**, `cpu_units` in `locals.tf`. A guest with twice the
weight gets twice the share. Weights do nothing while the threads are idle.

The weights are in the sizes table above. Their order is the point:

1. **Workers** weigh most, so applications win when the host is contended.
2. **Control planes** come next. etcd misses heartbeats when starved, and the
   API goes with it.
3. **System nodes** weigh least, at the Proxmox default. Their components can
   wait a moment.

Whether the weights and sizes are right shows on the Node pools dashboard in
Grafana. **CPU steal** is time a node's vCPUs were ready to run but the host ran
another guest: the noisy-neighbour signal. Sustained steal above about 5% on a
worker means the weights or the sizes need another look. Changing either is
[Resizing a node](../manual/maintenance/resizing-a-node.md).

## Workers run without CPU mitigations

The kernel protects against CPU flaws such as Meltdown and Spectre by making
every switch into the kernel more expensive. On this host's i7-8700 that cost is
high, and it falls hardest on work that makes many small system calls: Envoy,
Postgres, Redis.

Only the workers turn the protections off, with `mitigations=off`. One stays
on: Talos will not boot without `pti=on`, the Meltdown mitigation. What they
guard against is code on a node reading memory it should not, so each pool is
weighed by what it holds and who can run code on it:

| Pool | Mitigations | Why |
| --- | --- | --- |
| Control plane | On | etcd holds every Secret. Little is gained: nothing on it serves requests. |
| System node | On | It holds ArgoCD's credentials and the key that decrypts every secret in git. |
| Worker | Off | It runs this repo's own applications and the Gateways' Envoys. |

Moving Envoy to the worker put the Gateways' TLS keys on the node without
mitigations. That is a deliberate trade: the keys are for names only the mesh
can reach, the public path's certificate stays at Cloudflare, and Envoy is the
component that gains most from the cheaper system calls.

The arguments are part of the Talos image, not the machine configuration, so
workers install from their own image; see `opentofu/project/image.tf`. A worker
only picks up a change to them when it is upgraded, and it must be upgraded to
that image:

```bash
talosctl --nodes 10.10.10.21 upgrade --image "$(task tofu:output -- -raw worker_installer_image)"
```

Upgrading a worker to the image the other pools use turns its mitigations back
on. Check a node with:

```bash
talosctl --nodes 10.10.10.21 read /sys/devices/system/cpu/vulnerabilities/spectre_v2
```

```
Vulnerable
```
