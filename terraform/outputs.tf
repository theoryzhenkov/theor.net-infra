output "server_ip" {
  description = "Public IPv4 address of the server"
  value       = hcloud_server.web.ipv4_address
}

output "server_id" {
  description = "Hetzner server ID"
  value       = hcloud_server.web.id
}

output "server_status" {
  description = "Current server status"
  value       = hcloud_server.web.status
}
