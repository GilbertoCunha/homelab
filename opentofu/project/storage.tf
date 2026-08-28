# The workers' data disk. `locals.tf` gives them the disk; this turns it into
# something Kubernetes can hand out.
#
# The volume name and the path local-path-provisioner writes to are the same
# fact, and ArgoCD owns the provisioner, so the name is read back out of its
# Application rather than written here as well. Same arrangement as `cilium.tf`.
locals {
  local_path_app = yamldecode(file("${path.root}/../../gitops/system/base/local-path-provisioner/application.yaml"))

  # Talos mounts a user volume at /var/mnt/<name>, so the volume's name is the
  # last element of the path the provisioner is pointed at.
  local_path_volume = basename(local.local_path_app.spec.source.helm.valuesObject.nodePathMap[0].paths[0])
}
