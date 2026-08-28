# The cluster's storage

Talos ships no storage class. Until this existed, every `PersistentVolumeClaim`
in the cluster stayed `Pending` forever, and the pod behind it never scheduled.

## What is used

**Rancher's local-path-provisioner**, as the cluster's default storage class,
writing into a **Talos user volume** on a second disk on each worker.

A volume is a directory on one worker. There is no replication, no network
storage and no CSI driver.

## Why a second disk

Talos gives its install disk entirely to the system: the `EPHEMERAL` partition
holds container images, logs and node state, and grows to fill whatever is left.
Persistent volumes could live there, but then a workload filling its volume
would also stop the node pulling images, and `talosctl reset` would take the
data with it.

So each worker gets a second, empty disk. OpenTofu attaches it
(`opentofu/modules/talos-node/main.tf`) and Talos claims it as a user volume
(`opentofu/project/cluster.tf`):

```yaml
apiVersion: v1alpha1
kind: UserVolumeConfig
name: local-path-provisioner
provisioning:
  diskSelector:
    match: "!system_disk"
  minSize: 10GB
filesystem:
  type: xfs
```

`!system_disk` matches the only other disk the guest has, and leaving `maxSize`
off lets the volume grow to fill it.

## Why a user volume rather than a directory

Talos mounts a user volume at `/var/mnt/<name>` **and propagates that mount into
the kubelet container**. That second half is the point. The kubelet runs in a
container of its own, so a pod asking for a `hostPath` can only see paths the
kubelet can see. A plain directory such as `/var/local-path-provisioner` would
need a `machine.kubelet.extraMounts` bind mount before the provisioner's helper
pod could write to it. A user volume needs nothing.

The path and the volume name are the same fact, so they are written once. The
provisioner's `nodePathMap` in
`gitops/system/base/local-path-provisioner/application.yaml` holds
`/var/mnt/local-path-provisioner`, and `opentofu/project/storage.tf` reads the
last element of it back as the volume's name.

## What a volume costs you

The class binds with `WaitForFirstConsumer`: nothing is created until a pod is
scheduled, and the volume is then created on whichever worker that pod landed
on. From that moment the pod is pinned there. It cannot move, and if that
worker is lost, so is the volume.

That is acceptable here because every node is a guest on one host: losing the
host loses all three workers anyway, so replicating between them buys less than
it looks. It stops being acceptable as soon as something in the cluster holds
data that is not cheap to lose. Replicated storage is in the
[Backlog](../backlog.md).

Nothing sets `storageClassName`. `local-path` is the default class, so a claim
that names nothing gets it.
