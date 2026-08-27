# Cilium is the CNI, and also replaces kube-proxy. Talos ships Flannel by
# default; `cluster.tf` turns both that and kube-proxy off, which leaves every
# node NotReady until something installs a CNI.
#
# That something is Talos itself, but only once. The chart is rendered here at
# plan time and handed to the control planes as an inline manifest, so the
# cluster comes up with networking already in it and `tofu apply` still means
# "the cluster is up". Installing it afterwards would deadlock: the health check
# at the end of `cluster.tf` waits for nodes that cannot go Ready until Cilium
# exists.
#
# Talos creates those objects and never updates them, so this render is the
# bootstrap copy and nothing else. ArgoCD owns Cilium from then on. The version
# and the values both live in the Application read below, which is why there is
# no `values` block here. `docs/concepts/cilium.md` explains the whole shape.

provider "helm" {}

locals {
  cilium_app = yamldecode(file("${path.root}/../../gitops/system/base/cilium/cilium.yaml"))

  # The local API server proxy Talos runs on every node. Cilium is pointed at it
  # by the values above, and `cluster.tf` pins it in the machine configuration,
  # so the port is read from there rather than written in both places.
  kubeprism_port = local.cilium_app.spec.source.helm.valuesObject.k8sServicePort
}

data "helm_template" "cilium" {
  name       = "cilium"
  repository = local.cilium_app.spec.source.repoURL
  chart      = local.cilium_app.spec.source.chart
  version    = local.cilium_app.spec.source.targetRevision
  namespace  = local.cilium_app.spec.destination.namespace

  # The chart refuses to render without a Kubernetes version, and defaults to
  # one far older than this cluster. It reads the same pin the nodes do.
  kube_version = var.kubernetes_version

  values = [yamlencode(local.cilium_app.spec.source.helm.valuesObject)]
}
