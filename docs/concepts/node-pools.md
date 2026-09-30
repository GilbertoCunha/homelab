# Node pools

The cluster's nodes are split into three pools, so that the components running
the cluster and the applications running on it do not compete for the same
nodes.

| Pool | Nodes | Runs | Keeps others off with |
| --- | --- | --- | --- |
| Control plane | `cp-1` to `cp-3` | etcd, the API server, the scheduler, the controller manager | `node-role.kubernetes.io/control-plane:NoSchedule`, set by Talos |
| System | `system-1` to `system-2` | The cluster's own components | `homelab.grncunha.com/pool=system:NoSchedule` |
| Worker | `worker-1` to `worker-3` | Applications | Nothing |

## Sizes

This is the one place in the docs that says how many nodes there are and how
big they are. Everywhere else links here.

| Pool | Nodes | vCPU each | Memory each | Disks each | CPU weight |
| --- | --- | --- | --- | --- | --- |
| Control plane | 3 | 2 | 6 GiB | 40 GB | 150 |
| System | 2 | 2 | 8 GiB | 40 GB + 100 GB data | 100 |
| Worker | 3 | 6 | 20 GiB | 100 GB + 100 GB data | 200 |
| **Total** | **8** | **28** | **94 GiB** | | |

The host has 6 cores, 12 threads and 125 GiB of usable memory. That makes 2.3:1
CPU overcommit, and leaves about 31 GiB for the host itself. The cluster idles
at about one busy vCPU, so the overcommit only matters when the CPU weights
below have to decide who waits.

`opentofu/project/locals.tf` is what actually sets these. Change a size there
and update this table in the same commit. Addresses are in
[Networks and addresses](../architecture/networks.md). The data disk holds
persistent volumes; see [The cluster's storage](./storage.md).

## Why workers carry no taint

A **taint** is a mark on a node that repels every pod that does not
**tolerate** it. Only the system nodes carry one, so:

- An application needs no scheduling settings at all. It cannot land on a
  control plane or a system node, so it lands on a worker.
- A system component needs two settings, and both are its own business: a
  toleration, so it may land on a system node, and a `nodeSelector`, so it must.

A toleration alone is not enough. It allows a system node without requiring
one, and the pod would still land on a worker half the time.

## What runs where

| Where | What |
| --- | --- |
| System nodes only | ArgoCD, cert-manager, cloudflared, the CloudNativePG operator, both external-dns instances, Grafana, kgateway and every gateway's Envoy, kube-state-metrics, local-path-provisioner, metrics-server, Pyroscope and its Alloy, sops-secrets-operator, VictoriaLogs, VictoriaMetrics, Hubble relay and UI |
| Every node | Cilium's agent and its Envoy, node-exporter, the log collector |
| Workers | Every application, and every database CloudNativePG creates for one |
| Control planes or workers | Cilium's operator and CoreDNS. Their installers let them onto the control planes, not the system nodes, and they are left as installed |

The gateways and cloudflared count as system components. They are the way into
the cluster, so an application's load cannot starve them.

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

`opentofu/project/locals.tf` defines them for the nodes, in `system_pool`. Each
system component repeats them under `gitops/system/`, because a manifest
ArgoCD applies cannot read an OpenTofu value.

The key is not `node-role.kubernetes.io/system`. Kubernetes forbids a worker
from setting labels under `kubernetes.io`, and a system node is a worker as far
as Talos is concerned.

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
cp-2       node-role.kubernetes.io/control-plane
cp-3       node-role.kubernetes.io/control-plane
system-1   homelab.grncunha.com/pool
system-2   homelab.grncunha.com/pool
worker-1   <none>
worker-2   <none>
worker-3   <none>
```

## CPU weights

Every node is a guest on one host with 12 threads, and together they have more
vCPUs than that. When the host is busy, Proxmox shares the threads by each
guest's **CPU weight**, `cpu_units` in `locals.tf`. A guest with twice the
weight gets twice the share. Weights do nothing while the host is idle.

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
