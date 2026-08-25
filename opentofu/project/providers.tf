# Credentials never appear here. `sops exec-env` puts PROXMOX_VE_API_TOKEN in
# the environment for the life of a single command, and the provider reads it
# from there. See the Taskfile.
provider "proxmox" {
  endpoint = var.proxmox_endpoint
  insecure = var.proxmox_insecure
}

provider "talos" {}
