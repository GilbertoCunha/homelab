variable "name" {
  description = "Guest name in Proxmox, also the Kubernetes node name."
  type        = string
}

variable "vm_id" {
  description = "Proxmox guest id. Fixed per node so a rebuild reuses the same id."
  type        = number
}

variable "node_name" {
  description = "Proxmox host the guest runs on."
  type        = string
}

variable "cpu_cores" {
  description = "vCPUs given to the guest."
  type        = number
}

variable "memory_mb" {
  description = "Memory given to the guest, in MiB."
  type        = number
}

variable "disk_gb" {
  description = "Size of the system disk, in GiB. Talos installs itself here."
  type        = number
}

variable "data_disk_gb" {
  description = "Size of the data disk, in GiB. Zero leaves the guest with only its system disk."
  type        = number
  default     = 0
}

variable "ip_cidr" {
  description = "Static address of the guest, with prefix length. There is no DHCP on the guest bridge."
  type        = string
}

variable "gateway" {
  description = "Default gateway for the guest, which is the bridge address on the host."
  type        = string
}

variable "bridge" {
  description = "Proxmox bridge the guest attaches to."
  type        = string
}

variable "datastore_id" {
  description = "Proxmox storage holding the guest disk."
  type        = string
}

variable "boot_image_id" {
  description = "File id of the Talos image the guest boots from to reach maintenance mode."
  type        = string
}

variable "tags" {
  description = "Proxmox tags, used only to make the guest list readable."
  type        = list(string)
  default     = []
}
