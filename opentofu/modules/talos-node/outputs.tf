output "ipv4_address" {
  description = "Static address of the guest, without the prefix length."
  value       = split("/", var.ip_cidr)[0]
}

output "vm_id" {
  description = "Proxmox guest id."
  value       = proxmox_virtual_environment_vm.this.vm_id
}

output "name" {
  description = "Guest name, which is also the Kubernetes node name."
  value       = proxmox_virtual_environment_vm.this.name
}
