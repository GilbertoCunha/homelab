output "talosconfig" {
  description = "Client configuration for talosctl. Write it out with `task tofu:talosconfig`."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "kubeconfig" {
  description = "Client configuration for kubectl. Write it out with `task tofu:kubeconfig`."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "cluster_endpoint" {
  description = "Kubernetes API address, served on the control plane virtual IP."
  value       = local.cluster_endpoint
}

output "nodes" {
  description = "Node names mapped to their addresses."
  value       = local.node_ips
}

output "worker_installer_image" {
  description = "The image workers install and upgrade from. It carries their kernel arguments; see image.tf."
  value       = data.talos_image_factory_urls.workers.urls.installer
}
