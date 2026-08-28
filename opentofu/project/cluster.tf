# The cluster PKI: Talos and Kubernetes certificate authorities, and the tokens
# nodes join with. Generated once and kept in state, which is why state is
# encrypted before it reaches R2.
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

# Applies to every node regardless of role.
locals {
  common_patch = {
    machine = {
      install = {
        # virtio0 on the guest. Talos writes itself here on first apply, and
        # the node boots from disk from then on.
        disk = "/dev/vda"

        # The image the node writes to disk, which is not the image it booted.
        # Left unset, the provider installs plain Talos at whatever version it
        # was built against: the wrong version, and without the extensions the
        # factory image carries, so the guest agent silently never appears.
        image = data.talos_image_factory_urls.this.urls.installer
      }
      network = {
        nameservers = var.nameservers
      }
      features = {
        # On by default, and pinned here because Cilium is configured to reach
        # the API server through it.
        kubePrism = {
          enabled = true
          port    = local.kubeprism_port
        }
      }
    }
    cluster = {
      network = {
        podSubnets     = [var.pod_subnet]
        serviceSubnets = [var.service_subnet]

        # Talos would otherwise install Flannel, which cannot enforce a
        # NetworkPolicy and would collide with Cilium. See `cilium.tf`.
        cni = {
          name = "none"
        }
      }
      # Cilium replaces it.
      proxy = {
        disabled = true
      }
      # Three dedicated control planes exist precisely so workloads stay off
      # them. Flip this only if the cluster is ever collapsed to three nodes.
      allowSchedulingOnControlPlanes = false
    }
  }

  # Only the control planes apply inline manifests, and the rendered chart is
  # some 75 KB, so keeping it out of the worker configurations is worth the
  # conditional in `config_patches` below.
  cilium_patch = {
    cluster = {
      inlineManifests = [{
        name     = "cilium"
        contents = data.helm_template.cilium.manifest
      }]
    }
  }

  # The hostname is its own configuration document as of Talos 1.13, and setting
  # it in `machine.network` as well is rejected outright. `auto` generates a name
  # from the machine's identity and has to be turned off before a static one is
  # accepted; the two cannot both be set.
  hostname_patches = {
    for name, node in local.nodes : name => {
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = name
    }
  }

  # The workers' second disk, claimed as a user volume. Talos mounts a user
  # volume at /var/mnt/<name> and propagates that mount into the kubelet
  # container, which is the whole reason for doing it this way: a plain
  # directory under /var would need a `machine.kubelet.extraMounts` bind mount
  # before a hostPath pod could see it. local-path-provisioner writes here; see
  # docs/concepts/storage.md.
  #
  # `!system_disk` matches the only other disk the guest has. No maxSize, so
  # the volume grows to fill it.
  user_volume_patches = {
    for name, node in local.workers : name => {
      apiVersion = "v1alpha1"
      kind       = "UserVolumeConfig"
      name       = local.local_path_volume
      provisioning = {
        diskSelector = { match = "!system_disk" }
        minSize      = "10GB"
      }
      filesystem = { type = "xfs" }
    }
  }

  # Per-node networking. There is no DHCP on the guest bridge, so every address
  # is written out. The interface is matched by driver rather than by name,
  # because predictable names depend on the emulated hardware.
  node_patches = {
    for name, node in local.nodes : name => {
      machine = {
        network = {
          interfaces = [
            merge(
              {
                deviceSelector = { driver = "virtio_net" }
                addresses      = [node.ip_cidr]
                routes = [{
                  network = "0.0.0.0/0"
                  gateway = var.gateway
                }]
              },
              # The control planes share one address. Talos elects a holder and
              # moves it on failure, which is what makes the API endpoint
              # highly available without a load balancer in front.
              node.machine_type == "controlplane" ? { vip = { ip = var.cluster_vip } } : {},
            )
          ]
        }
      }
    }
  }
}

data "talos_machine_configuration" "this" {
  for_each = local.nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = each.value.machine_type
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
}

# The node boots the image into maintenance mode with the address its cloud-init
# drive gave it. This is the first moment it can be reached, and applying the
# configuration is what turns it into a cluster member.
resource "talos_machine_configuration_apply" "this" {
  for_each = local.nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.this[each.key].machine_configuration
  node                        = local.node_ips[each.key]

  # Each element is a separate patch, which is what lets the third one address a
  # different configuration document from the first two.
  config_patches = concat(
    [
      yamlencode(local.common_patch),
      yamlencode(local.node_patches[each.key]),
      yamlencode(local.hostname_patches[each.key]),
    ],
    each.value.machine_type == "controlplane" ? [yamlencode(local.cilium_patch)] : [],
    each.value.machine_type == "worker" ? [yamlencode(local.user_volume_patches[each.key])] : [],
  )

  depends_on = [module.talos_node]
}

# Runs against one control plane only. etcd forms from there and the other two
# join it; bootstrapping more than once would create split clusters.
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.first_control_plane

  depends_on = [talos_machine_configuration_apply.this]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.control_plane_ips
  nodes                = values(local.node_ips)
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.first_control_plane

  depends_on = [talos_machine_bootstrap.this]
}

# Makes `tofu apply` mean "the cluster is up", not "the VMs exist". Without it
# the run finishes long before Kubernetes is actually serving.
data "talos_cluster_health" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.control_plane_ips
  control_plane_nodes  = local.control_plane_ips
  worker_nodes         = [for k, v in local.workers : local.node_ips[k]]

  depends_on = [talos_cluster_kubeconfig.this]
}
