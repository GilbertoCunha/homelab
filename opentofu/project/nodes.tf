module "talos_node" {
  source   = "../modules/talos-node"
  for_each = local.nodes

  name         = each.key
  vm_id        = each.value.vm_id
  cpu_cores    = each.value.cpu_cores
  cpu_units    = each.value.cpu_units
  memory_mb    = each.value.memory_mb
  disk_gb      = each.value.disk_gb
  data_disk_gb = each.value.data_disk_gb
  ip_cidr      = each.value.ip_cidr
  # System nodes carry a third tag, so the guest list shows the pool. Adding
  # one to the other guests would change them for no reason.
  tags = concat(
    [var.cluster_name, each.value.machine_type],
    contains(keys(local.system_nodes), each.key) ? [local.system_pool.value] : [],
  )
  node_name     = var.proxmox_node_name
  datastore_id  = var.proxmox_datastore_id
  bridge        = var.proxmox_bridge
  gateway       = var.gateway
  boot_image_id = proxmox_download_file.talos.id
}
