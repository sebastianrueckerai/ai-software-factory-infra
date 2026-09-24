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
  description = "Hetzner Cloud server type for every node"
  type        = string
  default     = "cax31"
}

variable "location" {
  description = "Hetzner Cloud location for every node"
  type        = string
  default     = "fsn1"
}

variable "hcloud_token" {
  description = "Hetzner Cloud API token, from the seed bundle, never in Git"
  type        = string
  sensitive   = true
}

variable "home_cidr" {
  description = "Home address allowlisted for the Talos and Kubernetes APIs"
  type        = string
}
