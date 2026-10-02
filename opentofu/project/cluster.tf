# The cluster PKI: Talos and Kubernetes certificate authorities, and the tokens
# nodes join with. Generated once and kept in state, which is why state is
# encrypted before it reaches R2.
resource "talos_machine_secrets" "this" {
  # The contract, not the version the nodes run; see `talos_config_contract`.
  # The provider replaces this resource, and with it every certificate in the
  # cluster, if the value is ever lowered.
  talos_version = var.talos_config_contract
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
        # CoreDNS forwards to the nameservers above rather than through the
        # DNS cache Talos runs on each node. Talos' own Cilium guide lists that
        # forwarding as broken once Cilium masquerades in eBPF, which it does;
        # see `gitops/system/base/cilium/cilium.yaml`.
        hostDNS = {
          enabled              = true
          forwardKubeDNSToHost = false
        }
      }
    }
    cluster = {
      network = {
        podSubnets     = [local.pod_subnet]
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
      # The control plane is its own guest precisely so workloads stay off it.
      # Flip this only if the cluster is ever collapsed to a single node.
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

  # Every node with a second disk, which is every node but the control planes,
  # claims it as a user volume. Talos mounts a user volume at /var/mnt/<name>
  # and propagates that mount into the kubelet container, which is the whole
  # reason for doing it this way: a plain directory under /var would need a
  # `machine.kubelet.extraMounts` bind mount before a hostPath pod could see
  # it. local-path-provisioner writes here; see docs/concepts/storage.md.
  #
  # `!system_disk` matches the only other disk the guest has. No maxSize, so
  # the volume grows to fill it.
  user_volume_patches = {
    for name, node in local.nodes : name => {
      apiVersion = "v1alpha1"
      kind       = "UserVolumeConfig"
      name       = local.local_path_volume
      provisioning = {
        diskSelector = { match = "!system_disk" }
        minSize      = "10GB"
      }
      filesystem = { type = "xfs" }
    } if node.data_disk_gb > 0
  }

  # Workers install from their own image, which carries their kernel arguments;
  # see `image.tf`. This is the image a new worker installs from. The same
  # image is what `talos_machine.worker` below keeps a running one on.
  #
  # The label names the pool; see `worker_pool` in `locals.tf`.
  worker_patches = {
    for name, node in local.workers : name => {
      machine = {
        install = {
          image = data.talos_image_factory_urls.workers.urls.installer
        }
        nodeLabels = {
          (local.worker_pool.key) = local.worker_pool.value
        }
      }
    }
  }

  # Reserves the system nodes for the cluster's own components; see
  # docs/concepts/node-pools.md.
  #
  # The label is ordinary: Talos keeps it in step with this file. The taint is
  # not. Kubernetes lets a worker's kubelet set taints only when it first
  # registers the node, never afterwards, so `machine.nodeTaints` would fail on
  # a worker. `registerWithTaints` is the kubelet setting for that first
  # registration, which also means changing it here reaches a new node only.
  # To change the taint on a running node, use `kubectl taint`.
  system_pool_patches = {
    for name, node in local.system_nodes : name => {
      machine = {
        nodeLabels = {
          (local.system_pool.key) = local.system_pool.value
        }
        kubelet = {
          extraConfig = {
            registerWithTaints = [local.system_pool]
          }
        }
      }
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
              # moves it on failure. With one control plane there is nothing to
              # move it to; it stays so the API endpoint does not change when a
              # second one is added.
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

  cluster_name     = var.cluster_name
  cluster_endpoint = local.cluster_endpoint
  machine_type     = each.value.machine_type
  machine_secrets  = talos_machine_secrets.this.machine_secrets

  # The layout the configuration is written in, which is not the version the
  # nodes run. See `talos_config_contract`.
  talos_version = var.talos_config_contract

  # The version a node is born with. On a running cluster a change here is
  # carried out by `talos_cluster` below and by nothing else; see
  # `ignore_kubernetes_upgrade_drift`.
  kubernetes_version = var.kubernetes_version

  # Each element is a separate patch, which is what lets the third one address a
  # different configuration document from the first two.
  config_patches = concat(
    [
      yamlencode(local.common_patch),
      yamlencode(local.node_patches[each.key]),
      yamlencode(local.hostname_patches[each.key]),
    ],
    each.value.machine_type == "controlplane" ? [yamlencode(local.cilium_patch)] : [],
    each.value.data_disk_gb > 0 ? [yamlencode(local.user_volume_patches[each.key])] : [],
    contains(keys(local.system_nodes), each.key) ? [yamlencode(local.system_pool_patches[each.key])] : [],
    contains(keys(local.workers), each.key) ? [yamlencode(local.worker_patches[each.key])] : [],
  )
}

# What lets a node be drained before it is upgraded. Built from the cluster's
# secrets rather than read from a node, so it exists before the cluster does,
# and ephemeral, so it is never written to state.
ephemeral "talos_cluster_kubeconfig" "drain" {
  cluster_name    = var.cluster_name
  machine_secrets = talos_machine_secrets.this.machine_secrets
  endpoint        = local.cluster_endpoint
}

# A node: its configuration, and the Talos version it runs.
#
# A new node boots the image into maintenance mode with the address its
# cloud-init drive gave it. This is the first moment it can be reached, and
# applying the configuration is what turns it into a cluster member.
#
# A running node is kept on `image`. When `talos_version` changes, the next
# apply drains the node, installs the new version, reboots it and waits for it
# to come back. That is the whole of a Talos upgrade; see
# docs/manual/maintenance/upgrading-talos-and-kubernetes.md.
#
# One resource per pool, not one for every node, because only separate
# resources can wait for each other. The chain is control plane, system,
# workers: each pool is finished before the next starts, so a bad version
# stops at the control plane with the applications still running. Nodes inside
# one pool would upgrade together; each pool is a single node.
resource "talos_machine" "control_plane" {
  for_each = local.control_planes

  node                  = local.node_ips[each.key]
  client_configuration  = talos_machine_secrets.this.client_configuration
  machine_configuration = data.talos_machine_configuration.this[each.key].machine_configuration
  image                 = data.talos_image_factory_urls.this.urls.installer
  kubeconfig_wo         = ephemeral.talos_cluster_kubeconfig.drain.kubeconfig_raw

  # The Kubernetes version is in every node's configuration, as the tag on
  # five images. Without this, changing it would be pushed to every node at
  # once from here, with none of the ordering and health checks of the proper
  # procedure, which `talos_cluster` runs. With it, only those tags are left
  # out when deciding whether a node's configuration has changed.
  ignore_kubernetes_upgrade_drift = true

  depends_on = [module.talos_node]
}

resource "talos_machine" "system" {
  for_each = local.system_nodes

  node                            = local.node_ips[each.key]
  client_configuration            = talos_machine_secrets.this.client_configuration
  machine_configuration           = data.talos_machine_configuration.this[each.key].machine_configuration
  image                           = data.talos_image_factory_urls.this.urls.installer
  kubeconfig_wo                   = ephemeral.talos_cluster_kubeconfig.drain.kubeconfig_raw
  ignore_kubernetes_upgrade_drift = true

  depends_on = [module.talos_node, talos_machine.control_plane]
}

resource "talos_machine" "worker" {
  for_each = local.workers

  node                  = local.node_ips[each.key]
  client_configuration  = talos_machine_secrets.this.client_configuration
  machine_configuration = data.talos_machine_configuration.this[each.key].machine_configuration
  # The workers' own image, which carries their kernel arguments. It has to be
  # the one in `worker_patches`: the provider compares the image a node runs
  # with this, and reinstalls a node that boots anything else.
  image                           = data.talos_image_factory_urls.workers.urls.installer
  kubeconfig_wo                   = ephemeral.talos_cluster_kubeconfig.drain.kubeconfig_raw
  ignore_kubernetes_upgrade_drift = true

  depends_on = [module.talos_node, talos_machine.system]
}

# The cluster: etcd, started once, and the Kubernetes version it runs.
#
# Starting etcd runs against one control plane only. etcd forms from there and
# any others join it; doing it more than once would create split clusters.
#
# When `kubernetes_version` changes, the next apply upgrades the control
# plane's components one at a time, then each kubelet, checking health in
# between. That is the whole of a Kubernetes upgrade.
#
# After the nodes, so that when both versions change in one apply Talos goes
# first. The newer Talos is the one that knows the newer Kubernetes.
resource "talos_cluster" "this" {
  node                 = local.first_control_plane
  control_plane_nodes  = local.control_plane_ips
  client_configuration = talos_machine_secrets.this.client_configuration
  kubernetes_version   = var.kubernetes_version

  depends_on = [talos_machine.control_plane, talos_machine.system, talos_machine.worker]
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

  depends_on = [talos_cluster.this]
}

# Makes `tofu apply` mean "the cluster is up", not "the VMs exist". Without it
# the run finishes long before Kubernetes is actually serving.
data "talos_cluster_health" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.control_plane_ips
  control_plane_nodes  = local.control_plane_ips
  worker_nodes         = [for k, v in local.nodes : local.node_ips[k] if v.machine_type == "worker"]

  # A data source is read at plan time unless something it depends on is about
  # to change. Depending on the nodes and the cluster is what defers it when a
  # node is being added or upgraded: otherwise the plan itself waits for a node
  # that does not exist yet, and fails after ten minutes.
  depends_on = [talos_cluster_kubeconfig.this, talos_cluster.this]
}
