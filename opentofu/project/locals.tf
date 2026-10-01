# The one place a node is described. Everything else in OpenTofu derives from
# this map, so adding a worker means changing one count here.
#
# Three pools: control planes, system nodes for the cluster's own components,
# and workers for applications. docs/concepts/node-pools.md explains the split,
# and why each pool is a single node.
#
# The sizes below are copied into the table in docs/concepts/node-pools.md,
# with the totals against the host. Update it in the same commit.
# Disks are qcow2 and thin, so they cost far less than their size until used.
# `data_disk_gb` is the second disk Talos turns into the local-path-provisioner
# user volume, so a persistent volume never shares a partition with container
# images. Control planes run no workloads and get none.
#
# `cpu_units` is the guest's CPU weight in Proxmox: when the host is busy, a
# guest with a higher weight gets a larger share of it. Workers weigh most, so
# applications win; control planes next, so etcd never starves; system nodes
# least.
#
# Changing any size or weight here reboots the guest. See
# docs/manual/maintenance/resizing-a-node.md.
locals {
  control_planes = {
    for i in range(1) :
    "cp-${i + 1}" => {
      vm_id        = 111 + i
      ip_cidr      = "10.10.10.${11 + i}/24"
      cpu_cores    = 2
      memory_mb    = 8192
      disk_gb      = 40
      data_disk_gb = 0
      cpu_units    = 150
      machine_type = "controlplane"
    }
  }

  # Workers as far as Talos is concerned. What sets them apart is the label and
  # taint in `system_pool`, which keep applications off them.
  system_nodes = {
    for i in range(1) :
    "system-${i + 1}" => {
      vm_id        = 131 + i
      ip_cidr      = "10.10.10.${31 + i}/24"
      cpu_cores    = 2
      memory_mb    = 16384
      disk_gb      = 40
      data_disk_gb = 100
      cpu_units    = 100
      machine_type = "worker"
    }
  }

  # The label system components select, and the taint that keeps everything
  # else away. The key and value are repeated in every system component's
  # tolerations and nodeSelector under gitops/system/, which cannot read them
  # from here.
  system_pool = {
    key    = "homelab.grncunha.com/pool"
    value  = "system"
    effect = "NoSchedule"
  }

  # The label that marks a worker. No taint goes with it: applications need no
  # scheduling settings to land here, because every other node repels them. It
  # exists for the few things that must name the workers outright, which are
  # the Gateways' Envoys and the load balancer announcements under gitops/.
  worker_pool = {
    key   = local.system_pool.key
    value = "worker"
  }

  workers = {
    for i in range(1) :
    "worker-${i + 1}" => {
      vm_id        = 121 + i
      ip_cidr      = "10.10.10.${21 + i}/24"
      cpu_cores    = 10
      memory_mb    = 65536
      disk_gb      = 100
      data_disk_gb = 100
      cpu_units    = 200
      machine_type = "worker"
    }
  }

  nodes = merge(local.control_planes, local.system_nodes, local.workers)

  # Addresses without the prefix length, which is what talosctl and the
  # provider address nodes by.
  node_ips = { for k, v in local.nodes : k => split("/", v.ip_cidr)[0] }

  control_plane_ips = [for k, v in local.control_planes : local.node_ips[k]]

  # Bootstrap runs against exactly one control plane, however many there are.
  first_control_plane = local.control_plane_ips[0]

  cluster_endpoint = "https://${var.cluster_vip}:6443"
}
