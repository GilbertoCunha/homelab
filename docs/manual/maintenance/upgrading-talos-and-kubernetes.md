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

**For a new Talos minor version, read them against `cluster.tf`.** 1.14 to
1.15 is a minor version; 1.14.1 to 1.14.2 is not. See
[A new minor version](#a-new-minor-version) first.

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
| `talos_machine_secrets` changed or replaced | Wrong, and destructive: replacing it replaces every certificate in the cluster. Stop |

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

## A new minor version

`talos_version` is one value with two jobs: it is the Talos the nodes run, and
the version their configuration is generated for. They are kept the same on
purpose, so a node never runs one version with a configuration written for
another.

The cost is that a new minor version can change what the configuration is made
of. Talos keeps it in documents, one per subject, and `cluster.tf` patches them
by name. A new minor can rename a document, or add one with a default this
cluster does not want. 1.14 did both: it added Flannel and kube-proxy as
documents of their own, and the settings that had turned them off stopped
applying.

**Nothing checks this before a node is given the result.** The plan passes
either way. So for a minor version:

1. Read the release notes for configuration changes, and change the patches in
   `opentofu/project/cluster.tf` in the same pull request.
2. Apply as usual, and watch the first node.

| What happens | What it means |
| --- | --- |
| The apply stops on `cp-1` with `error applying machine configuration` and a message naming a document | Talos refused the configuration. The node is upgraded and still runs its old configuration, and nothing else has been touched. Fix the patch the message names and apply again |
| The apply finishes, and `kubectl -n kube-system get daemonsets` lists `kube-proxy` or `kube-flannel` | A default came back. Turn it off in `control_plane_patches` and apply again |

The control plane goes first for this reason: a configuration Talos refuses
stops there, with the applications still running.

## Checking it worked

```bash
talosctl --nodes 10.10.10.11 health
kubectl -n argocd get applications
```

Every health check passes, and every Application reads `Synced` and `Healthy`.
