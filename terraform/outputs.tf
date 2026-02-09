output "server_ip" {
  description = "Public IPv4 address of the server (persistent primary IP)"
  value       = hcloud_primary_ip.web_ipv4.ip_address
}

output "server_id" {
  description = "Hetzner server ID"
  value       = hcloud_server.web.id
}

output "server_status" {
  description = "Current server status"
  value       = hcloud_server.web.status
}

output "data_volume_id" {
  description = "Hetzner Cloud Volume ID"
  value       = hcloud_volume.data.id
}
