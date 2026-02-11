data "sops_file" "secrets" {
  source_file = "secrets/secrets.enc.yaml"
}

provider "hcloud" {
  token = data.sops_file.secrets.data["hcloud_token"]
}

provider "porkbun" {
  api_key        = data.sops_file.secrets.data["porkbun_api_key"]
  secret_api_key = data.sops_file.secrets.data["porkbun_secret_api_key"]
}

resource "hcloud_ssh_key" "deploy" {
  name       = "hetzner-theor.net-web-ssh-1"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIELtIN+wG3GGLHruiy+Bl3NNJFcAU7uK4Q3rbVD3ad18"
}

resource "hcloud_firewall" "web" {
  name = "${var.server_name}-firewall"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "3478"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_primary_ip" "web_ipv4" {
  name          = "${var.server_name}-ipv4"
  type          = "ipv4"
  location      = var.location
  auto_delete   = false
  assignee_type = "server"
}

resource "hcloud_server" "web" {
  name        = var.server_name
  server_type = var.server_type
  location    = var.location
  image       = "ubuntu-24.04"

  ssh_keys = [hcloud_ssh_key.deploy.id]

  firewall_ids = [hcloud_firewall.web.id]

  public_net {
    ipv4 = hcloud_primary_ip.web_ipv4.id
  }

  labels = {
    project = "theor-net"
    role    = "web"
  }
}

# Persistent data volume for PostgreSQL

resource "hcloud_volume" "data" {
  name     = "${var.server_name}-data"
  size     = 10 # GB, expandable later
  location = var.location
  format   = "ext4"
}

resource "hcloud_volume_attachment" "data" {
  volume_id = hcloud_volume.data.id
  server_id = hcloud_server.web.id
  automount = false # NixOS handles mounting
}

resource "null_resource" "volume_label" {
  depends_on = [hcloud_volume_attachment.data]

  triggers = {
    volume_id = hcloud_volume.data.id
  }

  provisioner "remote-exec" {
    inline = ["e2label /dev/disk/by-id/scsi-0HC_Volume_${hcloud_volume.data.id} theor-net-data-1"]
    connection {
      type = "ssh"
      host = hcloud_primary_ip.web_ipv4.ip_address
      user = "root"
    }
  }
}

# Backblaze B2 — off-site PostgreSQL backups

provider "b2" {
  application_key_id = data.sops_file.secrets.data["b2_key_id"]
  application_key    = data.sops_file.secrets.data["b2_app_key"]
}

resource "b2_bucket" "pg_backups" {
  bucket_name = "theor-net-pg-backups"
  bucket_type = "allPrivate"

  lifecycle_rules {
    file_name_prefix              = ""
    days_from_uploading_to_hiding = 30
  }
}

# DNS — theor.net A/AAAA records pointing to the server

resource "porkbun_dns_record" "theor_net_root" {
  domain   = "theor.net"
  name     = ""
  type     = "A"
  content  = hcloud_primary_ip.web_ipv4.ip_address
  ttl      = 600
  priority = 0
}

resource "porkbun_dns_record" "theor_net_cue" {
  domain   = "theor.net"
  name     = "cue"
  type     = "A"
  content  = hcloud_primary_ip.web_ipv4.ip_address
  ttl      = 600
  priority = 0
}

resource "porkbun_dns_record" "theor_net_leaves_wildcard" {
  domain   = "theor.net"
  name     = "*.leaves"
  type     = "A"
  content  = hcloud_primary_ip.web_ipv4.ip_address
  ttl      = 600
  priority = 0
}

resource "porkbun_dns_record" "theor_net_home" {
  domain   = "theor.net"
  name     = "home"
  type     = "A"
  content  = hcloud_primary_ip.web_ipv4.ip_address
  ttl      = 600
  priority = 0
}

resource "porkbun_dns_record" "theor_net_auth" {
  domain   = "theor.net"
  name     = "auth"
  type     = "A"
  content  = hcloud_primary_ip.web_ipv4.ip_address
  ttl      = 600
  priority = 0
}

resource "porkbun_dns_record" "theor_net_headscale" {
  domain   = "theor.net"
  name     = "headscale"
  type     = "A"
  content  = hcloud_primary_ip.web_ipv4.ip_address
  ttl      = 600
  priority = 0
}

resource "porkbun_dns_record" "theor_net_root_ipv6" {
  domain   = "theor.net"
  name     = ""
  type     = "AAAA"
  content  = hcloud_server.web.ipv6_address
  ttl      = 600
  priority = 0
}
