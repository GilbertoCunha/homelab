# Resizing a node

Changing a node's vCPUs, memory or CPU weight, on a cluster that is running.

**Every one of these changes reboots the guest.** The Proxmox provider cannot
change them live, so it restarts the VM to apply them. Each pool is one node, so
whatever that node runs is down until it is back:

| Node | Down while it reboots |
| --- | --- |
| `cp-1` | The Kubernetes API. Running pods keep serving; nothing can be deployed or rescheduled |
| `system-1` | ArgoCD, Grafana, metrics and logs. Metrics have a gap |
| `worker-1` | Every application, every Gateway and the tunnel |

A plain `task tofu:apply` changes every guest it has a change for at once. A
resize is applied one node at a time, with `-target`, so only one of those rows
is true at a time.

Node sizes and CPU weights live in `opentofu/project/locals.tf`. What the
weights do is in [Node pools](../../concepts/node-pools.md).

## 1. Changing the size

Edit the pool in `opentofu/project/locals.tf`: `cpu_cores`, `memory_mb` or
`cpu_units`. Then:

```bash
task tofu:plan
```

What the plan should show:

| What the plan shows | What it means |
| --- | --- |
| One `proxmox_virtual_environment_vm` updated in-place per node you resized | Correct |
| Any `proxmox_virtual_environment_vm` replaced | Wrong. A resize never rebuilds a guest. Stop and read the diff |
| Any `talos_machine` changed | Something else changed too. Apply that on its own first |

Update the sizes table in [Node pools](../../concepts/node-pools.md) in the
same commit. It is the only place in the docs that repeats them.

## 2. Resizing one node

Do this for each node in turn, and finish one before starting the next. The
examples use `worker-1`.

**A worker or a system node:** move its pods off first.

```bash
kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data
```

```
node/worker-1 drained
```

With one node in the pool there is nowhere for the pods to go: they stay
`Pending` until the node is back. The drain still stops them cleanly first. A
pod with a persistent volume could not move anyway, because its volume cannot.
See [The cluster's storage](../../concepts/storage.md).

**The drain retries forever on a database.** A CloudNativePG database with one
instance has a PodDisruptionBudget allowing no evictions, so the drain prints
this every 5 seconds:

```
error when evicting pods/"url-shortener-db-1" -n "project-url-shortener-prod" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
```

The database cannot leave this node anyway, because its volume cannot. Stop the
drain with Ctrl-C and run it again with `--disable-eviction`, which deletes pods
directly instead of evicting them, so the budget no longer applies:

```bash
kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data --disable-eviction
```

```
node/worker-1 drained
```

The database is down until the node is back and uncordoned. Its data stays on
its volume.

**The control plane:** nothing to move. etcd has one member, so the API is
down from the moment the guest stops until it is back. Check the cluster is
healthy first, so a problem afterwards is known to be new:

```bash
talosctl --nodes 10.10.10.11 health
```

Every check should pass. Do not continue if one fails.

Then apply the change to that node only. The escaped quotes are needed, because
the Taskfile passes the command through two shells:

```bash
task tofu:apply -- '-target=module.talos_node[\"worker-1\"]'
```

```
Apply complete! Resources: 0 added, 1 changed, 0 destroyed.
```

The warning about resource targeting is expected. The guest reboots during the
apply, so wait for the node to come back:

```bash
kubectl wait --for=condition=Ready node/worker-1 --timeout=10m
```

```
node/worker-1 condition met
```

Let pods back onto a node you drained:

```bash
kubectl uncordon worker-1
```

```
node/worker-1 uncordoned
```

Before the next node, check the whole cluster:

```bash
talosctl --nodes 10.10.10.11 health
```

Every check should pass.

## 3. Checking it worked

Once every node is done:

```bash
task tofu:plan
```

```
No changes. Your infrastructure matches the configuration.
```

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory
```

Each node shows its new vCPU count, and its memory in KiB. Expect a little
under the size you set, because the kernel keeps some for itself: a node given
1 GiB shows just under `1048576Ki`.

The Node pools dashboard in Grafana shows whether the new sizes are right:
CPU steal and pressure per node, and how much of each pool is requested.
