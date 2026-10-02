# Non-secret values only. Secrets arrive as environment variables from
# `sops exec-env`; see the Taskfile.

# Proxmox answers on the mesh at this name, with a real certificate.
proxmox_endpoint     = "https://proxmox.homelab.grncunha.com"
proxmox_node_name    = "homelab"
proxmox_datastore_id = "local"
proxmox_bridge       = "vmbr1"

cluster_name = "homelab"

# The versions the cluster runs. Changing either one upgrades the cluster on
# the next `task tofu:apply`; see
# docs/manual/maintenance/upgrading-talos-and-kubernetes.md.
#
# Kubernetes must be inside the range the Talos version supports. Check the
# support matrix before changing either of these:
# https://www.talos.dev/latest/introduction/support-matrix/
talos_version      = "v1.14.1"
kubernetes_version = "v1.37.1"

# The layout the machine configuration is written in. Talos 1.14 moved most
# settings into documents of their own, and the patches in cluster.tf are
# written for the 1.13 layout, which 1.14 still accepts. Generated in the 1.14
# layout with those patches, the configuration does not validate.
#
# Not the version the nodes run, and Renovate does not move it. It changes
# when the patches are rewritten, and never downwards: the provider compares
# it with the value in state, and lowering it replaces the cluster's
# certificates. `v1.13` counts as lower than `v1.13.9`, which is why the patch
# version is written out.
talos_config_contract = "v1.13.9"

# The CNI is not here. Talos ships Flannel by default; this cluster replaces it
# with Cilium, whose version and values live in
# gitops/system/base/cilium/cilium.yaml, because ArgoCD owns it.

# Guest network. These mirror the values in ansible/group_vars/all.yaml and the
# network table in README.md, which is the registry for both.
cluster_vip    = "10.10.10.10"
gateway        = "10.10.10.1"
nameservers    = ["1.1.1.1", "1.0.0.1"]
service_subnet = "10.96.0.0/12"
# The pod subnet is not here: Cilium routes it, so it lives with Cilium's
# values in gitops/system/base/cilium/cilium.yaml.
