# Cilium is the CNI, and also replaces kube-proxy. Talos ships Flannel by
# default; `cluster.tf` turns both that and kube-proxy off, which leaves every
# node NotReady until something installs a CNI.
#
# That something is Talos itself. The chart is rendered here at plan time and
# handed to the control planes as an inline manifest, so the cluster comes up
# with networking already in it and `tofu apply` still means "the cluster is up".
# Installing it afterwards would deadlock: the health check at the end of
# `cluster.tf` waits for nodes that cannot go Ready until Cilium exists.

provider "helm" {}

data "helm_template" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = var.cilium_version
  namespace  = "kube-system"

  # The chart refuses to render without a Kubernetes version, and defaults to
  # one far older than this cluster. It reads the same pin the nodes do.
  kube_version = var.kubernetes_version

  values = [yamlencode({
    # Pod addresses come from the podCIDR Kubernetes gives each node, which is
    # carved out of `pod_subnet`. Cilium does not need its own address
    # management on top of that.
    ipam = {
      mode = "kubernetes"
    }

    kubeProxyReplacement = true

    # Replacing kube-proxy means Cilium cannot reach the API server through a
    # Service, because Services are the thing it has not set up yet. KubePrism
    # is the local proxy Talos runs for exactly this bootstrap problem.
    k8sServiceHost = "localhost"
    k8sServicePort = local.kubeprism_port

    # Talos mounts the cgroup filesystem itself and gives out capabilities
    # rather than blanket privilege, so the chart's defaults do not apply.
    cgroup = {
      autoMount = {
        enabled = false
      }
      hostRoot = "/sys/fs/cgroup"
    }
    securityContext = {
      capabilities = {
        ciliumAgent = [
          "CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN",
          "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID",
        ]
        cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
      }
    }

    hubble = {
      relay = {
        enabled = true
      }
      ui = {
        enabled = true
      }
      # Certificates are minted in the cluster by a job. The chart's default is
      # to mint them while rendering, which would put a fresh private key in
      # the machine configuration on every plan: a secret in the state and a
      # change to apply every single run.
      tls = {
        auto = {
          enabled = true
          method  = "cronJob"
        }
      }
    }
  })]
}
