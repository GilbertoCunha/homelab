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

# Marked sensitive to keep it out of plan output, not because it is secret: the
# chart is rendered so that it carries no keys at all. It is 75 KB, and printing
# it on every plan buries the changes worth reading. `tofu output -raw` still
# prints it, which is all `task tofu:cilium-manifest` needs.
output "cilium_manifest" {
  description = "The rendered Cilium chart, as Talos applies it. Write it out with `task tofu:cilium-manifest` when it has to be applied by hand."
  value       = data.helm_template.cilium.manifest
  sensitive   = true
}
