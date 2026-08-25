# The Image Factory builds a Talos image carrying the extensions named here and
# returns an id for it. Changing the extension list produces a new id, which is
# what makes the image reproducible rather than something uploaded by hand.
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = [
          # Lets Proxmox see the guest's address and shut it down cleanly.
          "siderolabs/qemu-guest-agent",
          # Not needed yet. Longhorn and most other CSI drivers require it, and
          # adding an extension later costs a rolling upgrade of every node, so
          # it is cheaper to carry it from the start.
          "siderolabs/iscsi-tools",
        ]
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

# Proxmox pulls the image itself rather than it being uploaded from here.
resource "proxmox_download_file" "talos" {
  node_name    = var.proxmox_node_name
  datastore_id = var.proxmox_datastore_id
  content_type = "iso"
  url          = data.talos_image_factory_urls.this.urls.iso

  # The factory URL carries the schematic id, which changes whenever the
  # extension list does. Naming the file after both keeps the two images apart
  # instead of one silently overwriting the other.
  file_name = "talos-${var.talos_version}-${substr(talos_image_factory_schematic.this.id, 0, 12)}-nocloud-amd64.iso"
}
