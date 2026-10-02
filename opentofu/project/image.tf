# The Image Factory builds a Talos image carrying the extensions named here and
# returns an id for it. Changing the extension list produces a new id, which is
# what makes the image reproducible rather than something uploaded by hand.
locals {
  talos_extensions = [
    # Lets Proxmox see the guest's address and shut it down cleanly.
    "siderolabs/qemu-guest-agent",
    # Not needed yet. Longhorn and most other CSI drivers require it, and
    # adding an extension later costs a rolling upgrade of every node, so
    # it is cheaper to carry it from the start.
    "siderolabs/iscsi-tools",
  ]
}

resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = local.talos_extensions
      }
    }
  })
}

# Workers run without the kernel's CPU vulnerability mitigations; see
# docs/concepts/node-pools.md for why only them. Kernel arguments are part of
# the image: the nodes boot the command line baked into it, not one from the
# machine configuration.
#
# Talos' own `pti=on` stays. Talos checks for it at boot and stops before the
# network comes up without it, so the Meltdown mitigation is the one that
# remains on.
resource "talos_image_factory_schematic" "workers" {
  schematic = yamlencode({
    customization = {
      extraKernelArgs = ["mitigations=off"]
      systemExtensions = {
        officialExtensions = local.talos_extensions
      }
    }
  })
}

data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "nocloud"
  architecture  = "amd64"
}

data "talos_image_factory_urls" "workers" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.workers.id
  platform      = "nocloud"
  architecture  = "amd64"
}

# Proxmox pulls the image itself rather than it being uploaded from here.
resource "proxmox_download_file" "talos" {
  node_name    = var.proxmox_node_name
  datastore_id = var.proxmox_datastore_id
  content_type = "iso"
  url          = data.talos_image_factory_urls.this.urls.iso

  file_name = local.talos_boot_image
}

locals {
  # Named after the schematic and not the Talos version. A guest boots this
  # once, to be installed; an upgrade never reads it. With the version in the
  # name, every upgrade renamed the file and changed the CD drive of every
  # guest to match. Now an upgrade replaces the file in place and no guest is
  # touched.
  #
  # The schematic stays in the name: it changes whenever the extension list
  # does, and two schematics must not overwrite each other.
  talos_boot_image = "talos-${substr(talos_image_factory_schematic.this.id, 0, 12)}-nocloud-amd64.iso"

  # The id Proxmox gives the file above. Written out rather than read from
  # the download, so that replacing the download is not a change to the
  # guests that name it.
  talos_boot_image_id = "${var.proxmox_datastore_id}:iso/${local.talos_boot_image}"
}
