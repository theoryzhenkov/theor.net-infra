variable "server_name" {
  description = "Name of the Hetzner server"
  type        = string
  default     = "theor-net-web"
}

variable "server_type" {
  description = "Hetzner server type"
  type        = string
  default     = "cx32"
}

variable "location" {
  description = "Hetzner datacenter location"
  type        = string
  default     = "nbg1"
}
