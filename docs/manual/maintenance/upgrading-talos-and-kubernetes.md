# Upgrading Talos and Kubernetes

Moving the nodes to a newer Talos, or the cluster to a newer Kubernetes, on a
cluster that is running.

Both are the same three steps: **merge the pull request, pull, apply.**
OpenTofu does the upgrade.

| Upgrade | What the apply does | What restarts |
| --- | --- | --- |
| Talos, the operating system on each node | Drains a node, installs the new version, reboots it, waits. Control plane, then system node, then worker | Each node reboots, one at a time |
| Kubernetes | Upgrades the control plane's components one at a time, then each kubelet, checking health in between | The control plane's components, then each kubelet. No reboot |

Renovate opens a pull request for each. **Merging it upgrades nothing.** The
version in git is what the cluster should run, and the next apply is what makes
it so. So a merge without an apply leaves the plan showing an upgrade that has
not happened yet.

If both have a new version, merge both and apply once. Talos goes first.

## Before you start

**Read the release notes.** They are in the pull request.

**Check the two versions fit together.** Kubernetes must be inside the range
the Talos version supports:
<https://www.talos.dev/latest/introduction/support-matrix/>

**Pick a time.** Each pool is one node, so what a node runs is down while it
reboots. The table in [Resizing a node](./resizing-a-node.md) says what that
is. A Talos upgrade reboots all three in turn; allow half an hour.

**Check the cluster is healthy now**, so a problem afterwards is known to be
new:

```bash
export TALOSCONFIG=$PWD/talosconfig
talosctl --nodes 10.10.10.11 health
```

Every check should pass. Do not continue if one fails.

## 1. Merging and reading the plan

Merge the pull request. Then:

```bash
git pull
task tofu:plan
```

| What the plan shows | What it means |
| --- | --- |
| The three `talos_machine` resources updated, and the image download replaced | A Talos upgrade. Correct |
| `talos_cluster` updated, with `kubernetes_version` changing. The `talos_machine` resources are listed too, with nothing under them | A Kubernetes upgrade. Correct |
| Any `proxmox_virtual_environment_vm` changed or replaced | Wrong. An upgrade does not touch a guest. Stop and read the diff |
| `talos_machine_secrets` replaced | Wrong, and destructive: it replaces every certificate in the cluster. Stop. `talos_config_contract` was lowered |

## 2. Applying

```bash
task tofu:apply
```

Leave it running. It finishes when the last node is back and the cluster
reports healthy.

Then check every node is on the new version:

```bash
kubectl get nodes -o wide
```

```
NAME       STATUS   ROLES           VERSION   INTERNAL-IP   OS-IMAGE
cp-1       Ready    control-plane   v1.37.1   10.10.10.11   Talos (v1.14.1)
system-1   Ready    <none>          v1.37.1   10.10.10.31   Talos (v1.14.1)
worker-1   Ready    <none>          v1.37.1   10.10.10.21   Talos (v1.14.1)
```

`Ready`, with the new Kubernetes version under `VERSION` and the new Talos
under `OS-IMAGE`, on all three.

## 3. Checking the worker kept its kernel arguments

After a Talos upgrade only:

```bash
talosctl --nodes 10.10.10.21 read /sys/devices/system/cpu/vulnerabilities/spectre_v2
```

```
Vulnerable
```

Anything else means the worker runs the other pools' image. See
[Node pools](../../concepts/node-pools.md#workers-run-without-cpu-mitigations).

## When the apply stops part-way

Run `task tofu:apply` again first. The upgrade is done one node at a time and
picks up where it stopped: a node already on the new version is left alone.

| What you see | What to do |
| --- | --- |
| `draining node`, and it does not move on | A pod is refusing to be evicted. `kubectl get pods -A -o wide \| grep <node>` shows what is left. Delete it by hand and apply again |
| A node is `Ready,SchedulingDisabled` after a failed run | `kubectl uncordon <node>` |
| A node does not come back | Talos keeps the version it had: `talosctl --nodes <address> rollback`. If it does not answer at all, open its console in Proxmox, reset it, and pick the other entry in the boot menu |
| `error upgrading Kubernetes`, with `connection refused` | The API server was still restarting. Wait for `talosctl --nodes 10.10.10.11 health` to pass, and apply again |

## The version that does not move

`talos_config_contract` in `opentofu/project/terraform.tfvars` looks like a
Talos version and is not the one the nodes run. It is the layout the node
configuration is written in. Renovate leaves it alone, and so should an
upgrade.

| | `talos_version` | `talos_config_contract` |
| --- | --- | --- |
| What it is | The Talos the nodes run | The layout of their configuration |
| Who changes it | Renovate | You, when rewriting the patches in `cluster.tf` |
| Lowering it | Downgrades the nodes | **Replaces every certificate in the cluster** |

## Checking it worked

```bash
talosctl --nodes 10.10.10.11 health
kubectl -n argocd get applications
```

Every health check passes, and every Application reads `Synced` and `Healthy`.
