variable "cluster_name" {
  type    = string
  default = "sf"
}

variable "node_count" {
  type    = number
  default = 3
  validation {
    condition     = var.node_count >= 3 && var.node_count % 2 == 1
    error_message = "Node count must be odd and at least three (etcd quorum)."
  }
}

variable "server_type" {
  type    = string
  default = "cax31"
}

variable "location" {
  type    = string
  default = "fsn1"
}

variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "home_cidr" {
  description = "Home address allowlisted for the Talos and Kubernetes APIs"
  type        = string
}
