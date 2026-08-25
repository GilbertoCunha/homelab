module "talos_node" {
  source   = "../modules/talos-node"
  for_each = local.nodes

  name          = each.key
  vm_id         = each.value.vm_id
  cpu_cores     = each.value.cpu_cores
  memory_mb     = each.value.memory_mb
  disk_gb       = each.value.disk_gb
  ip_cidr       = each.value.ip_cidr
  tags          = [var.cluster_name, each.value.machine_type]
  node_name     = var.proxmox_node_name
  datastore_id  = var.proxmox_datastore_id
  bridge        = var.proxmox_bridge
  gateway       = var.gateway
  boot_image_id = proxmox_download_file.talos.id
}
