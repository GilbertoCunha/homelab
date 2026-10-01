# Upgrading Talos and Kubernetes

Moving the nodes to a newer Talos, or the cluster to a newer Kubernetes, on a
cluster that is running.

They are two separate upgrades:

| Upgrade | Done with | What restarts |
| --- | --- | --- |
| Talos, the operating system on each node | `talosctl upgrade`, one node at a time | The node reboots |
| Kubernetes | `talosctl upgrade-k8s`, once for the whole cluster | The control plane's components, then each kubelet. No reboot |

Renovate opens a pull request for each. **Merging it upgrades nothing.** It
records the version a rebuilt cluster would be born with, so it is the last
step here, not the first.

If both have a new version, do Talos first. A Talos version supports a set
range of Kubernetes versions, and the newer Talos is the one that knows the
newer Kubernetes.

## The short way

The cluster is disposable. If nothing in it is worth keeping, merge the pull
request and rebuild: the new cluster starts at the new versions, and none of
the rest of this page is needed. **Starting over**, at the end of
[Bootstrap GitOps](../provisioning/4-bootstrap-gitops.md), is the whole
procedure.

## Before you start

**Read the release notes.** They are in the pull request.

**Check the two versions fit together.** Kubernetes must be inside the range
the Talos version supports:
<https://www.talos.dev/latest/introduction/support-matrix/>

**Bring `talosctl` to the Talos version you are moving to.** An older one does
not know the newer versions.

```bash
brew upgrade talosctl
talosctl version --client
```

```
Client:
	Tag:         v1.13.10
```

**Check the cluster is healthy now**, so a problem afterwards is known to be
new:

```bash
export TALOSCONFIG=$PWD/talosconfig
talosctl --nodes 10.10.10.11 health
```

Every check should pass. Do not continue if one fails.

## Upgrading Talos

### 1. Working out the images

A node upgrades from an installer image. The workers have their own, because
it carries their kernel arguments; see
[Node pools](../../concepts/node-pools.md#workers-run-without-cpu-mitigations).
Both are the image the node runs now, with the new version on the end:

```bash
new=v1.13.10
image="$(task tofu:output -- -raw installer_image | sed "s/:[^:]*$/:${new}/")"
worker_image="$(task tofu:output -- -raw worker_installer_image | sed "s/:[^:]*$/:${new}/")"
echo "$image"
echo "$worker_image"
```

```
factory.talos.dev/nocloud-installer/6ebbfe35c822...:v1.13.10
factory.talos.dev/nocloud-installer/0991719b1879...:v1.13.10
```

Two different long ids, and the new version on both. If OpenTofu says the
output `installer_image` does not exist, run `task tofu:apply` once. It adds
the output and changes nothing else.

### 2. Upgrading one node at a time

In this order, finishing each before the next:

| Order | Node | Address | Image |
| --- | --- | --- | --- |
| 1 | `cp-1` | `10.10.10.11` | `$image` |
| 2 | `system-1` | `10.10.10.31` | `$image` |
| 3 | `worker-1` | `10.10.10.21` | `$worker_image` |

Each node is its whole pool, so what it runs is down while it reboots. The
table in [Resizing a node](./resizing-a-node.md) says what that is.

```bash
talosctl --nodes 10.10.10.11 upgrade --image "$image"
```

The command drains the node, installs the new version, reboots, and waits for
the node to come back. Allow several minutes. Then check the node reports the
new version:

```bash
kubectl get nodes -o wide
```

```
NAME       STATUS   ROLES           VERSION   INTERNAL-IP   OS-IMAGE
cp-1       Ready    control-plane   v1.36.2   10.10.10.11   Talos (v1.13.10)
system-1   Ready    <none>          v1.36.2   10.10.10.31   Talos (v1.13.9)
worker-1   Ready    <none>          v1.36.2   10.10.10.21   Talos (v1.13.9)
```

`Ready`, and the new version under `OS-IMAGE` for the node you just did.

**If the upgrade waits on the drain.** A CloudNativePG database with one
instance refuses to be evicted, and the drain gives up after 5 minutes. Delete
the database pod yourself, as in [Resizing a node](./resizing-a-node.md), and
run the upgrade again.

**If a node does not come back.** Talos keeps the version it had. From your own
machine:

```bash
talosctl --nodes 10.10.10.11 rollback
```

If the node does not answer at all, open its console in Proxmox, reset it, and
pick the other entry in the boot menu.

### 3. Checking the worker kept its kernel arguments

```bash
talosctl --nodes 10.10.10.21 read /sys/devices/system/cpu/vulnerabilities/spectre_v2
```

```
Vulnerable
```

Anything else means the worker was upgraded from the wrong image. Upgrade it
again, with `$worker_image`.

### 4. Recording it

Merge the pull request. Then:

```bash
git pull
task tofu:plan
```

The plan should change the machine configurations and the boot image, because
both name the Talos version. Applying it changes nothing on a node that is
already upgraded.

| What the plan shows | What it means |
| --- | --- |
| `talos_machine_configuration_apply` updated, and the image download replaced | Correct |
| Any `proxmox_virtual_environment_vm` replaced | Wrong. An upgrade never rebuilds a guest. Stop and read the diff |

```bash
task tofu:apply
```

## Upgrading Kubernetes

**Do not start from OpenTofu.** Applying the new version there changes the
node configurations directly, without the checks and the ordering
`upgrade-k8s` does.

### 1. Seeing what would happen

The version is written without the `v`:

```bash
talosctl --nodes 10.10.10.11 upgrade-k8s --to 1.36.3 --dry-run
```

It prints the plan and changes nothing. Read it for warnings before going on.

### 2. Upgrading

```bash
talosctl --nodes 10.10.10.11 upgrade-k8s --to 1.36.3
```

It upgrades the API server, the controller manager and the scheduler, then the
kubelet on every node. There is one control plane, so the API drops for a
moment while its components restart. Running pods keep serving.

```bash
kubectl get nodes
```

```
NAME       STATUS   ROLES           AGE   VERSION
cp-1       Ready    control-plane   12d   v1.36.3
system-1   Ready    <none>          12d   v1.36.3
worker-1   Ready    <none>          12d   v1.36.3
```

Every node on the new version.

### 3. Recording it

Merge the pull request. Then:

```bash
git pull
task tofu:plan
```

The plan should update the machine configurations and nothing else. Apply it.
The nodes already run what it describes.

## Checking it worked

```bash
talosctl --nodes 10.10.10.11 health
kubectl -n argocd get applications
```

Every health check passes, and every Application reads `Synced` and `Healthy`.
