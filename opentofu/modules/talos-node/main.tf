terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

# One Talos guest. Everything that differs between a control plane and a worker
# arrives as a variable, so this file describes the shape of a node exactly once.
resource "proxmox_virtual_environment_vm" "this" {
  name      = var.name
  vm_id     = var.vm_id
  node_name = var.node_name
  tags      = var.tags

  # Talos manages its own shutdown; the guest agent reports back once the
  # extension is running.
  #
  # Every refresh asks the agent for the guest's addresses, so a guest whose
  # agent is not answering blocks the read rather than failing it. The default
  # wait is fifteen minutes, per guest, which turns a plan into a hang. A guest
  # that is working answers within a minute of booting, so this fails fast
  # enough to be readable and still leaves room for a slow boot.
  agent {
    enabled = true
    timeout = "3m"
  }

  operating_system {
    type = "l26"
  }

  # `host` passes the i7-8700 feature set straight through, which Kubernetes
  # workloads and etcd both benefit from. There is only one host to migrate
  # between, so nothing is lost by not abstracting the CPU.
  cpu {
    cores = var.cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.memory_mb
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "virtio0"
    size         = var.disk_gb
    file_format  = "qcow2"
    iothread     = true
    discard      = "on"
  }

  # A second disk, on the workers only, so persistent volumes do not share a
  # partition with container images and logs. Talos claims it as the
  # `local-path-provisioner` user volume; see `cluster.tf`.
  dynamic "disk" {
    for_each = var.data_disk_gb > 0 ? [var.data_disk_gb] : []

    content {
      datastore_id = var.datastore_id
      interface    = "virtio1"
      size         = disk.value
      file_format  = "qcow2"
      iothread     = true
      discard      = "on"
    }
  }

  # Proxmox puts the cloud-init drive on ide2, so the boot image goes on ide3.
  cdrom {
    file_id   = var.boot_image_id
    interface = "ide3"
  }

  # Disk first, image second. An empty disk is not bootable, so a new guest
  # falls through to the image and comes up in maintenance mode. Once Talos has
  # installed itself the disk wins, and the guest stops returning to
  # maintenance mode on every reboot.
  boot_order = ["virtio0", "ide3"]

  network_device {
    bridge = var.bridge
  }

  # The guest bridge has no DHCP server, so a node booting the Talos image would
  # otherwise reach maintenance mode with no address and be unreachable. Talos'
  # nocloud platform reads this drive and brings the interface up, which is what
  # lets the machine configuration be applied over the network afterwards.
  initialization {
    datastore_id = var.datastore_id

    ip_config {
      ipv4 {
        address = var.ip_cidr
        gateway = var.gateway
      }
    }
  }

  # Talos writes its own state to the disk on install, and the machine
  # configuration owns everything inside the guest from that point on.
  lifecycle {
    ignore_changes = [initialization]
  }
}
