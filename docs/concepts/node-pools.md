# Node pools

The cluster's nodes are split into three pools, so that the components running
the cluster and the applications running on it do not compete for the same
nodes.

| Pool | Nodes | Runs | Keeps others off with |
| --- | --- | --- | --- |
| Control plane | `cp-1` to `cp-3` | etcd, the API server, the scheduler, the controller manager | `node-role.kubernetes.io/control-plane:NoSchedule`, set by Talos |
| System | `system-1` to `system-2` | The cluster's own components | `homelab.grncunha.com/pool=system:NoSchedule` |
| Worker | `worker-1` to `worker-3` | Applications | Nothing |

Sizes and addresses are in [Networks and addresses](../architecture/networks.md).
Every node is described in `opentofu/project/locals.tf`.

## Why workers carry no taint

A **taint** is a mark on a node that repels every pod that does not
**tolerate** it. Only the system nodes carry one, so:

- An application needs no scheduling settings at all. It cannot land on a
  control plane or a system node, so it lands on a worker.
- A system component needs two settings, and both are its own business: a
  toleration, so it may land on a system node, and a `nodeSelector`, so it must.

A toleration alone is not enough. It allows a system node without requiring
one, and the pod would still land on a worker half the time.

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
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints[*].key
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

All eight nodes are guests on one host with 12 threads, and together they have
more vCPUs than that. When the host is busy, Proxmox shares the threads by each
guest's **CPU weight**, `cpu_units` in `locals.tf`. A guest with twice the
weight gets twice the share. Weights do nothing while the host is idle.
