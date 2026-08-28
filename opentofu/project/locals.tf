# The one place a node is described. Everything else derives from this map, so
# adding a worker means adding a line here and nothing else.
#
# Sizing, against a 6-core/12-thread host with 125 GiB of usable memory:
#   18 vCPU total is 1.5:1 overcommit, which idles comfortably.
#   72 GiB allocated leaves roughly 53 GiB for the host, Headscale and Caddy.
# Disks are qcow2 and thin, so the 720 GiB below costs far less until used.
# `data_disk_gb` is the second disk Talos turns into the local-path-provisioner
# user volume, so a persistent volume never shares a partition with container
# images. Control planes run no workloads and get none.
locals {
  control_planes = {
    for i in range(3) :
    "cp-${i + 1}" => {
      vm_id        = 111 + i
      ip_cidr      = "10.10.10.${11 + i}/24"
      cpu_cores    = 2
      memory_mb    = 4096
      disk_gb      = 40
      data_disk_gb = 0
      machine_type = "controlplane"
    }
  }

  workers = {
    for i in range(3) :
    "worker-${i + 1}" => {
      vm_id        = 121 + i
      ip_cidr      = "10.10.10.${21 + i}/24"
      cpu_cores    = 4
      memory_mb    = 20480
      disk_gb      = 100
      data_disk_gb = 100
      machine_type = "worker"
    }
  }

  nodes = merge(local.control_planes, local.workers)

  # Addresses without the prefix length, which is what talosctl and the
  # provider address nodes by.
  node_ips = { for k, v in local.nodes : k => split("/", v.ip_cidr)[0] }

  control_plane_ips = [for k, v in local.control_planes : local.node_ips[k]]

  # Bootstrap runs against exactly one control plane, never all three.
  first_control_plane = local.control_plane_ips[0]

  cluster_endpoint = "https://${var.cluster_vip}:6443"
}
