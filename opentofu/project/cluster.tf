# The cluster PKI: Talos and Kubernetes certificate authorities, and the tokens
# nodes join with. Generated once and kept in state, which is why state is
# encrypted before it reaches R2.
resource "talos_machine_secrets" "this" {
  # Only read when the secrets are first generated. The provider records it,
  # and replaces the resource -- every certificate in the cluster -- if the
  # recorded version is ever lowered. Following `talos_version` would turn
  # reverting a bad Talos upgrade into exactly that, so after creation a
  # change to the version is ignored here.
  talos_version = var.talos_version

  lifecycle {
    ignore_changes = [talos_version]
  }
}

# The node configuration is generated for `talos_version`, and what is written
# here changes it. Talos keeps the configuration in documents, one per subject,
# and each element of a list below patches one document: that is why these are
# lists of small objects rather than one large one.
#
# The set of documents belongs to the Talos minor version. A new minor can
# rename one or add one with a default this cluster does not want, the way
# 1.14 added Flannel and kube-proxy as documents of their own. Nothing checks
# that before a node is given the result, so a new minor version means reading
# its release notes against this file. See
# docs/manual/maintenance/upgrading-talos-and-kubernetes.md.
locals {
  # Applies to every node regardless of role.
  common_patches = [
    {
      apiVersion  = "v1alpha1"
      kind        = "ResolverConfig"
      nameservers = [for address in var.nameservers : { address = address }]
      # CoreDNS forwards to the nameservers above rather than through the
      # DNS cache Talos runs on each node. Talos' own Cilium guide lists that
      # forwarding as broken once Cilium masquerades in eBPF, which it does;
      # see `gitops/system/base/cilium/cilium.yaml`.
      hostDNS = {
        enabled              = true
        forwardKubeDNSToHost = false
      }
    },
    {
      # On by default, and pinned here because Cilium is configured to reach
      # the API server through it.
      apiVersion = "v1alpha1"
      kind       = "KubePrismConfig"
      port       = local.kubeprism_port
    },
    {
      apiVersion     = "v1alpha1"
      kind           = "KubeNetworkConfig"
      podSubnets     = [local.pod_subnet]
      serviceSubnets = [var.service_subnet]
    },
  ]

  # Applies to the control planes only: these documents do not exist in a
  # worker's configuration, and a patch for a missing document is an error.
  #
  # The control plane keeps the taint Talos gives it, so workloads stay off it
  # with nothing written here. It is its own guest precisely for that.
  control_plane_patches = [
    {
      # Talos would otherwise install Flannel, which cannot enforce a
      # NetworkPolicy and would collide with Cilium. See `cilium.tf`. Removing
      # the document is how Flannel is turned off: no CNI is installed without
      # one.
      apiVersion = "v1alpha1"
      kind       = "KubeFlannelCNIConfig"
      "$patch"   = "delete"
    },
    {
      # Cilium replaces it. Unlike Flannel, removing this document is not
      # enough: kube-proxy is installed without one. It has to be switched
      # off.
      apiVersion = "v1alpha1"
      kind       = "KubeProxyConfig"
      enabled    = false
    },
    # Only the control planes apply inline manifests, and the rendered chart is
    # some 75 KB, so it is kept out of the worker configurations.
    {
      cluster = {
        inlineManifests = [{
          name     = "cilium"
          contents = data.helm_template.cilium.manifest
        }]
      }
    },
  ]

  # What a node installs itself from, and onto which disk.
  #
  # One patch for each node, holding both the image and the disk. They cannot
  # be two patches, one common and one for the workers' image: a second patch
  # to this document drops the disk selector the first one set, and the
  # configuration no longer validates.
  install_patches = {
    for name, node in local.nodes : name => {
      apiVersion = "v1alpha1"
      kind       = "UnattendedInstallConfig"
      installer = {
        # The image the node writes to disk, which is not the image it booted.
        # Left unset, Talos installs its plain image: without the extensions
        # the factory image carries, so the guest agent silently never appears.
        #
        # Workers install from their own, which carries their kernel
        # arguments; see `image.tf`. It is the image `talos_machine` keeps a
        # running node on, and the two have to agree.
        image = local.installer_images[name]
      }
      provisioning = {
        # virtio0 on the guest. Talos writes itself here on first apply, and
        # the node boots from disk from then on.
        diskSelector = { match = "disk.dev_path == \"/dev/vda\"" }
      }
    }
  }

  # The installer image for each node: the workers' own for a worker, and the
  # common one for every other pool.
  installer_images = {
    for name, node in local.nodes : name => (
      contains(keys(local.workers), name)
      ? data.talos_image_factory_urls.workers.urls.installer
      : data.talos_image_factory_urls.this.urls.installer
    )
  }

  # `auto` generates a name from the machine's identity and has to be turned
  # off before a static one is accepted; the two cannot both be set.
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
  # bind mount into the kubelet before a hostPath pod could see it.
  # local-path-provisioner writes here; see docs/concepts/storage.md.
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

  # The label names the pool; see `worker_pool` in `locals.tf`.
  worker_patches = [
    {
      apiVersion = "v1alpha1"
      kind       = "KubeNodeConfig"
      labels     = { (local.worker_pool.key) = local.worker_pool.value }
    },
  ]

  # Reserves the system nodes for the cluster's own components; see
  # docs/concepts/node-pools.md.
  #
  # The label is ordinary: Talos keeps it in step with this file. The taint is
  # not. Kubernetes lets a worker's kubelet set taints only when it first
  # registers the node, never afterwards. `registerWithTaints` is the kubelet
  # setting for that first registration, which also means changing it here
  # reaches a new node only. To change the taint on a running node, use
  # `kubectl taint`.
  system_pool_patches = [
    {
      apiVersion = "v1alpha1"
      kind       = "KubeNodeConfig"
      labels     = { (local.system_pool.key) = local.system_pool.value }
    },
    {
      apiVersion = "v1alpha1"
      kind       = "KubeletConfig"
      config     = { registerWithTaints = [local.system_pool] }
    },
  ]

  # Per-node networking. There is no DHCP on the guest bridge, so every address
  # is written out. The interface is matched by driver rather than by name,
  # because predictable names depend on the emulated hardware.
  #
  # Still in the original document, the one without a `kind`. Talos 1.14
  # generates no newer document for interfaces and reads them from here.
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

  # The version the nodes run, and the version the configuration is generated
  # for. One value on purpose: see the note above the patches.
  talos_version = var.talos_version

  # The version a node is born with. On a running cluster a change here is
  # carried out by `talos_cluster` below and by nothing else; see
  # `ignore_kubernetes_upgrade_drift`.
  kubernetes_version = var.kubernetes_version

  # One patch per element, and no document patched twice.
  #
  # Each list is encoded before the lists are joined. The patches are objects
  # of different shapes, and a conditional needs both of its results to be the
  # same type; as text they are.
  config_patches = concat(
    [for patch in local.common_patches : yamlencode(patch)],
    [
      yamlencode(local.install_patches[each.key]),
      yamlencode(local.node_patches[each.key]),
      yamlencode(local.hostname_patches[each.key]),
    ],
    each.value.machine_type == "controlplane" ? [for patch in local.control_plane_patches : yamlencode(patch)] : [],
    each.value.data_disk_gb > 0 ? [yamlencode(local.user_volume_patches[each.key])] : [],
    contains(keys(local.system_nodes), each.key) ? [for patch in local.system_pool_patches : yamlencode(patch)] : [],
    contains(keys(local.workers), each.key) ? [for patch in local.worker_patches : yamlencode(patch)] : [],
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
  image                 = local.installer_images[each.key]
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
  image                           = local.installer_images[each.key]
  kubeconfig_wo                   = ephemeral.talos_cluster_kubeconfig.drain.kubeconfig_raw
  ignore_kubernetes_upgrade_drift = true

  depends_on = [module.talos_node, talos_machine.control_plane]
}

resource "talos_machine" "worker" {
  for_each = local.workers

  node                  = local.node_ips[each.key]
  client_configuration  = talos_machine_secrets.this.client_configuration
  machine_configuration = data.talos_machine_configuration.this[each.key].machine_configuration
  # The workers' own image. The provider compares the image a node runs with
  # this, and reinstalls a node that runs anything else.
  image                           = local.installer_images[each.key]
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
