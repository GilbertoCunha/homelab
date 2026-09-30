# Resizing a node

Changing a node's vCPUs, memory or CPU weight, on a cluster that is running.

**Every one of these changes reboots the guest.** The Proxmox provider cannot
change them live, so it restarts the VM to apply them. A plain `task tofu:apply`
changes every guest at once, which reboots all three control planes together:
etcd loses quorum and the API goes down. So a resize is applied one node at a
time, with `-target`.

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
| Any `talos_machine_configuration_apply` changed | Something else changed too. Apply that on its own first |

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

A pod with a persistent volume on this node cannot move, because its volume
cannot. It stays `Pending` until the node is back. See
[The cluster's storage](../../concepts/storage.md).

**A control plane:** check that etcd has all three members before taking one
away.

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
