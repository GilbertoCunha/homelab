terraform {
  required_version = ">= 1.10"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.11"
    }
    # Renders the Cilium chart at plan time. Nothing is installed with it: the
    # rendered manifest is handed to Talos, which applies it during bootstrap.
    helm = {
      source  = "opentofu/helm"
      version = "~> 3.0"
    }
  }
}
