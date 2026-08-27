# Non-secret values only. Secrets arrive as environment variables from
# `sops exec-env`; see the Taskfile.

# Proxmox answers on the mesh at this name, with a real certificate.
proxmox_endpoint     = "https://proxmox.homelab.grncunha.com"
proxmox_node_name    = "homelab"
proxmox_datastore_id = "local"
proxmox_bridge       = "vmbr1"

cluster_name = "homelab"

# Talos 1.13 supports Kubernetes 1.31 to 1.36. Check the support matrix before
# changing either of these:
# https://www.talos.dev/latest/introduction/support-matrix/
talos_version      = "v1.13.9"
kubernetes_version = "v1.36.2"

# The CNI is not here. Talos ships Flannel by default; this cluster replaces it
# with Cilium, whose version and values live in
# gitops/system/base/cilium/cilium.yaml, because ArgoCD owns it.

# Guest network. These mirror the values in ansible/group_vars/all.yaml and the
# network table in README.md, which is the registry for both.
cluster_vip    = "10.10.10.10"
gateway        = "10.10.10.1"
nameservers    = ["1.1.1.1", "1.0.0.1"]
pod_subnet     = "10.244.0.0/16"
service_subnet = "10.96.0.0/12"
