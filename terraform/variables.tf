variable "server_name" {
  description = "Name of the Hetzner server"
  type        = string
  default     = "theor.net-web-1"
}

variable "server_type" {
  description = "Hetzner server type"
  type        = string
  default     = "cx33"
}

variable "location" {
  description = "Hetzner location"
  type        = string
  default     = "nbg1"
}
