variable "proxmox_endpoint" {
  description = "Proxmox API URL. Reached over the mesh, so this is a mesh name, never the public address."
  type        = string
}

variable "proxmox_insecure" {
  description = "Skip TLS verification against Proxmox. Only true when talking to port 8006 directly, which uses a self-signed certificate."
  type        = bool
  default     = false
}

variable "proxmox_node_name" {
  description = "Name of the Proxmox host in the cluster. There is only one."
  type        = string
}

variable "proxmox_datastore_id" {
  description = "Proxmox storage holding guest disks and the Talos image."
  type        = string
}

variable "proxmox_bridge" {
  description = "Bridge the guests attach to."
  type        = string
}

variable "cluster_name" {
  description = "Talos cluster name, also used as the Kubernetes context name."
  type        = string
}

variable "talos_version" {
  description = "Talos Linux version. Decides which Kubernetes versions are supported."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version, pinned independently of Talos and within the range Talos supports."
  type        = string
}

variable "cluster_vip" {
  description = "Virtual address shared by the control planes. Talos moves it between them, so no load balancer is needed."
  type        = string
}

variable "gateway" {
  description = "Default gateway for the guests, which is the bridge address on the host."
  type        = string
}

variable "nameservers" {
  description = "Resolvers the nodes use. Guests reach the internet through NAT on the host."
  type        = list(string)
}

variable "pod_subnet" {
  description = "CIDR for pod addresses. Recorded in the README network table."
  type        = string
}

variable "service_subnet" {
  description = "CIDR for service addresses. Recorded in the README network table."
  type        = string
}

variable "cilium_version" {
  description = "Cilium chart version. Rendered at plan time and applied by Talos at bootstrap; see docs/manual/maintenance/upgrading-cilium.md."
  type        = string
}
